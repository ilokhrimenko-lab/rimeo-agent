using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RimeoAgent.HttpServer;

/// ES256 (ECDSA P-256 + SHA-256) JWT validator for endpoints exposed to the
/// public internet through the named tunnel. Faithful port of the macOS
/// JWTValidator.swift; the server signer is rimeo_webapp/jwt_signer.py.
/// Claims used: aud (== this agent's tunnel hostname), exp.
///
/// Enforcement is gated to named-tunnel mode in ApiRouter (NamedHostname
/// non-empty), so this stays inert on quick/local tunnels where the server
/// does not sign tokens.
public static class JwtValidator
{
    public enum Failure
    {
        Missing,
        Malformed,
        WrongAlgorithm,
        Expired,
        WrongAudience,
        InvalidSignature,
        NotConfigured,
    }

    // SubjectPublicKeyInfo / PKIX PEM. The matching private key lives only in the
    // rimeo.app server env (JWT_PRIVATE_KEY_PEM). Same key baked into the macOS
    // build (JWTValidator.swift).
    private const string PublicKeyPem =
        "-----BEGIN PUBLIC KEY-----\n" +
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUiawXlrjeQhLWfXjgs9FiuHjqOMt\n" +
        "h0XfbBreh55YjgoyMsGys7emSXv3pBlUOeYWXGM3y+ZCiSPYuZNyHLWu2w==\n" +
        "-----END PUBLIC KEY-----";

    private const int ClockSkewSeconds = 60;

    public static bool IsConfigured => !string.IsNullOrWhiteSpace(PublicKeyPem);

    public static string FailureReason(Failure f) => f switch
    {
        Failure.Missing          => "missing",
        Failure.Malformed        => "malformed",
        Failure.WrongAlgorithm   => "wrongAlgorithm",
        Failure.Expired          => "expired",
        Failure.WrongAudience    => "wrongAudience",
        Failure.InvalidSignature => "invalidSignature",
        Failure.NotConfigured    => "notConfigured",
        _                        => "unknown",
    };

    /// Returns null when the token is valid, or a Failure describing why not.
    /// Never throws — parse/crypto errors map to a Failure.
    public static Failure? Validate(string? rawToken, string expectedAudience)
    {
        if (!IsConfigured) return null;                              // dev / pre-rollout: no-op
        if (string.IsNullOrEmpty(expectedAudience)) return Failure.WrongAudience;
        if (string.IsNullOrEmpty(rawToken)) return Failure.Missing;

        var parts = rawToken.Split('.');
        if (parts.Length != 3) return Failure.Malformed;

        byte[] headerData, payloadData, sigData;
        try
        {
            headerData  = Base64UrlDecode(parts[0]);
            payloadData = Base64UrlDecode(parts[1]);
            sigData     = Base64UrlDecode(parts[2]);
        }
        catch { return Failure.Malformed; }

        try
        {
            using var headerDoc = JsonDocument.Parse(headerData);
            if (!headerDoc.RootElement.TryGetProperty("alg", out var algEl)
                || algEl.GetString() is not { } alg)
                return Failure.Malformed;
            if (alg != "ES256") return Failure.WrongAlgorithm;

            using var payloadDoc = JsonDocument.Parse(payloadData);
            var root = payloadDoc.RootElement;

            if (!TryGetExp(root, out double exp)) return Failure.Malformed;
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (now > exp + ClockSkewSeconds) return Failure.Expired;

            if (!root.TryGetProperty("aud", out var audEl)
                || audEl.GetString() is not { Length: > 0 } aud)
                return Failure.WrongAudience;
            if (!AudienceMatches(aud, expectedAudience)) return Failure.WrongAudience;

            using var ecdsa = ECDsa.Create();
            try { ecdsa.ImportFromPem(PublicKeyPem); }
            catch { return Failure.NotConfigured; }

            // JWT ES256 signature is raw r||s (fixed-width) = IEEE P1363.
            var signingInput = Encoding.ASCII.GetBytes(parts[0] + "." + parts[1]);
            bool ok = ecdsa.VerifyData(
                signingInput, sigData,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
            return ok ? null : Failure.InvalidSignature;
        }
        catch { return Failure.Malformed; }
    }

    public static string? ExtractToken(AgentRequest req)
    {
        if (req.QueryParams.TryGetValue("token", out var q) && !string.IsNullOrEmpty(q))
            return q;
        if (req.Headers.TryGetValue("authorization", out var auth) && !string.IsNullOrEmpty(auth))
        {
            if (auth.StartsWith("bearer ", StringComparison.OrdinalIgnoreCase))
                return auth.Substring(7).Trim();
            return auth;
        }
        return null;
    }

    private static bool TryGetExp(JsonElement payload, out double exp)
    {
        exp = 0;
        if (!payload.TryGetProperty("exp", out var e)) return false;
        switch (e.ValueKind)
        {
            case JsonValueKind.Number:
                return e.TryGetDouble(out exp);
            case JsonValueKind.String:
                return double.TryParse(e.GetString(), NumberStyles.Any,
                    CultureInfo.InvariantCulture, out exp);
            default:
                return false;
        }
    }

    private static bool AudienceMatches(string aud, string expected)
    {
        if (aud == expected) return true;
        // Tolerate scheme/host shapes: token may carry the bare hostname while
        // expected is derived from a URL ("https://host"), or vice versa.
        var a = StripScheme(aud);
        var e = StripScheme(expected);
        return a.Length > 0 && a == e;
    }

    private static string StripScheme(string s)
    {
        var v = s;
        foreach (var prefix in new[] { "https://", "http://" })
            if (v.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                v = v.Substring(prefix.Length);
        var slash = v.IndexOf('/');
        if (slash >= 0) v = v.Substring(0, slash);
        return v;
    }

    private static byte[] Base64UrlDecode(string s)
    {
        var str = s.Replace('-', '+').Replace('_', '/');
        switch (str.Length % 4)
        {
            case 2: str += "=="; break;
            case 3: str += "=";  break;
        }
        return Convert.FromBase64String(str);
    }
}
