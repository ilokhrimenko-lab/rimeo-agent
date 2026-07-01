using System.Security.Cryptography;
using System.Text;
using RimeoAgent.Config;
using RimeoAgent.Services;

namespace RimeoAgent.HttpServer;

// Fail-CLOSED security primitives — port of macOS SecurityGates.swift. Covers the
// agent security audit:
//   • 6001  jwtGate fail-open   → AccessControl.Decide (deny when no tunnel + no PSK)
//   • 6004  control endpoints   → AccessControl.ControlProtectedPaths
//   • 6003  CORS "*"            → CorsPolicy (explicit origin allow-list)
//   • 6002  arbitrary file read → LibraryPathGuard (canonicalize + root allow-list)
//   • 6005  unsigned auto-update → UpdateSignatureVerifier (detached ES256 over the zip)
//   • 6006  helper download     → ComponentHostPolicy (domain pinning)

public enum AccessDecision { Allow, Deny }

public static class AccessControl
{
    // Data-exposing endpoints (audio bytes, waveform, art, library JSON, logs).
    public static readonly HashSet<string> DataProtectedPaths = new()
    {
        "/stream", "/waveform", "/artwork", "/api/data", "/api/logs",
    };

    // Mutating / control endpoints. Unauthenticated = account takeover, forced
    // public exposure, arbitrary explorer /select, note tampering (task 6004).
    public static readonly HashSet<string> ControlProtectedPaths = new()
    {
        "/reveal",
        "/api/save_note", "/api/save_exclusions", "/api/rename_history",
        "/api/send_tg",
        "/api/link_account", "/api/unlink_account",
        "/api/agent_login", "/api/agent_signup",
        "/api/tunnel/start", "/api/tunnel/stop",
        "/api/report_bug",
    };

    public static bool RequiresAuth(string path) =>
        DataProtectedPaths.Contains(path) || ControlProtectedPaths.Contains(path);

    /// Pure authorization core. Order: valid PSK → allow; else no named tunnel ⇒
    /// DENY (6001 fail-closed — was allow); else allow iff the server JWT validates.
    public static AccessDecision Decide(
        string lanSecret, string? providedToken, string namedHostname,
        string? jwtToken, Func<string?, string, JwtValidator.Failure?> validate)
    {
        if (!string.IsNullOrEmpty(lanSecret) && !string.IsNullOrEmpty(providedToken)
            && ConstantTimeEquals(providedToken!, lanSecret))
            return AccessDecision.Allow;
        if (string.IsNullOrEmpty(namedHostname)) return AccessDecision.Deny; // 6001
        return validate(jwtToken, namedHostname) == null
            ? AccessDecision.Allow : AccessDecision.Deny;
    }

    /// Constant-time PSK comparison (no length/prefix timing leak).
    public static bool ConstantTimeEquals(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));
}

public static class CorsPolicy
{
    // Only the Rimeo web player talks to the agent cross-origin. Native iOS / relay
    // clients are not browsers and need no CORS. A wildcard "*" let ANY page fetch
    // /api/data and /stream (task 6003).
    public static readonly HashSet<string> AllowedOrigins = new()
    {
        "https://rimeo.app", "https://www.rimeo.app",
    };

    public static bool IsAllowed(string? origin) =>
        !string.IsNullOrEmpty(origin) && AllowedOrigins.Contains(origin!);

    public static Dictionary<string, string> Headers(string? origin)
    {
        if (!IsAllowed(origin)) return new Dictionary<string, string>();
        return new Dictionary<string, string>
        {
            ["Access-Control-Allow-Origin"]  = origin!,
            ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
            ["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Range",
            ["Vary"]                         = "Origin",
        };
    }
}

public static class LibraryPathGuard
{
    private static readonly object RootsLock = new();
    private static string _cachedRootsSignature = "";
    private static List<string> _cachedCanonicalRoots = new();

    /// Canonical absolute path: normalise `..` (GetFullPath) and resolve a
    /// symlink/junction to its final target so an in-library link cannot escape.
    public static string Canonical(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            try
            {
                var target = new FileInfo(full).ResolveLinkTarget(returnFinalTarget: true);
                if (target != null) return Path.GetFullPath(target.FullName);
                var dtarget = new DirectoryInfo(full).ResolveLinkTarget(returnFinalTarget: true);
                if (dtarget != null) return Path.GetFullPath(dtarget.FullName);
            }
            catch { /* not a link / does not exist — use the normalised path */ }
            return full;
        }
        catch { return path; }
    }

    /// Directory-prefix containment over already-canonical inputs (case-insensitive;
    /// Windows FS), with a separator boundary so root "D:\Music" does NOT authorise
    /// "D:\Music-secret".
    public static bool IsContainedCanonical(string candidate, IEnumerable<string> canonicalRoots)
    {
        if (string.IsNullOrEmpty(candidate)) return false;
        foreach (var r in canonicalRoots)
        {
            if (string.IsNullOrEmpty(r)) continue;
            if (string.Equals(candidate, r, StringComparison.OrdinalIgnoreCase)) return true;
            var boundary = r.EndsWith(Path.DirectorySeparatorChar) ? r : r + Path.DirectorySeparatorChar;
            if (candidate.StartsWith(boundary, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    public static bool IsContained(string path, IEnumerable<string> roots)
        => IsContainedCanonical(Canonical(path), roots.Select(Canonical));

    /// Parent folder of every library track + the agent's cache (converted audio)
    /// and the Rekordbox share/db dir (cover art).
    public static List<string> AllowedRoots()
    {
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var t in RekordboxParser.Shared.Parse().Tracks)
        {
            if (string.IsNullOrEmpty(t.Location)) continue;
            var dir = Path.GetDirectoryName(t.Location);
            if (!string.IsNullOrEmpty(dir)) roots.Add(dir!);
        }
        if (!string.IsNullOrEmpty(AppConfig.Shared.CacheDir)) roots.Add(AppConfig.Shared.CacheDir);
        var db = AppConfig.Shared.DbPath;
        if (!string.IsNullOrEmpty(db))
        {
            var rb = Path.GetDirectoryName(db);
            if (!string.IsNullOrEmpty(rb))
            {
                roots.Add(rb!);
                roots.Add(Path.Combine(rb!, "share"));
            }
        }
        return roots.ToList();
    }

    /// Canonicalized roots, memoized on a cheap library signature so the hot
    /// streaming path does not canonicalize every root on every (range) request.
    private static List<string> CanonicalAllowedRoots()
    {
        var tracks = RekordboxParser.Shared.Parse().Tracks;
        var signature = $"{tracks.Count}|{(tracks.Count > 0 ? tracks[0].Location : "")}|{(tracks.Count > 0 ? tracks[^1].Location : "")}";
        lock (RootsLock)
        {
            if (signature == _cachedRootsSignature && _cachedCanonicalRoots.Count > 0)
                return _cachedCanonicalRoots;
            _cachedCanonicalRoots = AllowedRoots().Select(Canonical).ToList();
            _cachedRootsSignature = signature;
            return _cachedCanonicalRoots;
        }
    }

    public static bool IsAllowed(string path) =>
        !string.IsNullOrEmpty(path) && IsContainedCanonical(Canonical(path), CanonicalAllowedRoots());
}

public sealed class UpdateSignatureException : Exception
{
    public UpdateSignatureException(string message) : base(message) { }
}

public static class UpdateSignatureVerifier
{
    // Contents of update_pub.pem (PKIX/SPKI). Matching private key lives ONLY in
    // release CI (secret UPDATE_SIGNING_KEY) and signs update.zip → update.zip.sig.
    // Same key as the macOS agent, so one signature verifies on both platforms.
    public const string UpdatePublicKeyPem =
        "-----BEGIN PUBLIC KEY-----\n" +
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE13+tB8Bq9f/Hi7ez4nff0roiRz4E\n" +
        "LGxTQT37N0MMd+jwfqh4P+vmK4oMBsrvwhxkIRB60rgWcVbr8irPMYJLEw==\n" +
        "-----END PUBLIC KEY-----";

    /// Verify an update archive against its detached ECDSA-P256 / SHA-256 (DER)
    /// signature — produced by `openssl dgst -sha256 -sign update_priv.pem`.
    /// Throws (fail-CLOSED) when the .sig is absent or does not verify; the caller
    /// MUST NOT apply the update on throw.
    public static void VerifyZipSignature(string zipPath, string sigPath)
        => VerifyZipSignature(zipPath, sigPath, UpdatePublicKeyPem);

    public static void VerifyZipSignature(string zipPath, string sigPath, string publicKeyPem)
    {
        if (!File.Exists(sigPath))
            throw new UpdateSignatureException($"Update signature file missing: {sigPath}");

        var sig = File.ReadAllBytes(sigPath);
        byte[] hash;
        using (var sha = SHA256.Create())
        using (var fs = File.OpenRead(zipPath))
            hash = sha.ComputeHash(fs);

        using var ecdsa = ECDsa.Create();
        try { ecdsa.ImportFromPem(publicKeyPem); }
        catch (Exception ex) { throw new UpdateSignatureException($"Bad update public key: {ex.Message}"); }

        bool ok;
        try { ok = ecdsa.VerifyHash(hash, sig, DSASignatureFormat.Rfc3279DerSequence); }
        catch { ok = false; }
        if (!ok) throw new UpdateSignatureException("Update archive signature is invalid");
    }
}

public static class ComponentHostPolicy
{
    // Hosts we accept helper-binary (cloudflared / ffmpeg / ffprobe) downloads
    // from. Pinning the host means a compromised manifest cannot redirect the
    // download to an attacker server to drop an executable (task 6006).
    public static readonly HashSet<string> AllowedHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "rimeo.app", "www.rimeo.app",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    };

    public static bool IsAllowed(string urlString)
    {
        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var uri)) return false;
        if (!string.Equals(uri.Scheme, "https", StringComparison.OrdinalIgnoreCase)) return false;
        return AllowedHosts.Contains(uri.Host);
    }
}
