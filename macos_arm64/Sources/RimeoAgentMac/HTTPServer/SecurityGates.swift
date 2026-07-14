import Foundation
import CryptoKit

// Security hardening primitives shared by the HTTP layer and the updater.
// Every decision here is fail-CLOSED: an unknown/misconfigured state denies
// access rather than granting it. The pure functions (no singleton access) are
// unit-tested in Tests/RimeoAgentTests/SecurityGatesTests.swift.
//
// Covers the agent security audit:
//   • 6001  jwtGate fail-open      → AccessControl.decide (deny when no tunnel + no PSK)
//   • 6004  control endpoints      → AccessControl.controlProtectedPaths
//   • 6003  CORS "*"               → CORSPolicy (explicit origin allow-list)
//   • 6002  arbitrary file read    → LibraryPathGuard (canonicalize + root allow-list)
//   • 6005  unsigned auto-update   → UpdateSignatureVerifier (Team ID + codesign)
//   • 6006  helper-binary download → ComponentHostPolicy (domain pinning)

// MARK: - Access control (6001 fail-closed gate, 6004 control-endpoint auth)

enum AccessDecision: Equatable {
    case allow
    case deny
}

enum AccessControl {
    /// Endpoints that expose user data (audio bytes, waveform, art, the full
    /// library JSON, logs) over the public named tunnel.
    static let dataProtectedPaths: Set<String> = [
        "/stream", "/waveform", "/artwork", "/api/data", "/api/logs",
    ]

    /// Mutating / control endpoints. Left unauthenticated these enable account
    /// takeover (/api/link_account), forced public exposure (/api/tunnel/start),
    /// arbitrary `open -R` (/reveal) and note/exclusion tampering (task 6004).
    static let controlProtectedPaths: Set<String> = [
        "/reveal",
        "/api/save_note", "/api/save_exclusions", "/api/rename_history",
        "/api/send_tg",
        "/api/link_account", "/api/unlink_account",
        "/api/agent_login", "/api/agent_signup",
        "/api/tunnel/start", "/api/tunnel/stop",
        "/api/report_bug",
        // Playlist mutations (Фаза 0 — плейлисты из iOS). Unauthenticated writes
        // would let anyone tamper with a user's library overlay. Kept as a single
        // list; /api/playlist/recommendations stays PUBLIC (like /api/similar).
        "/api/playlist/create", "/api/playlist/add", "/api/playlist/remove",
        "/api/playlist/reorder", "/api/playlist/rename", "/api/playlist/delete",
        "/api/playlist/create_folder",
        // Фаза 6 — the ONLY endpoint that writes the user's real Rekordbox
        // master.db (create/rename/delete playlists, rewrite membership). Every
        // route above it edits a Rimeo-owned overlay file we can throw away; this
        // one mutates the irreplaceable library. Unauthenticated, anyone on the
        // same café/hotel Wi-Fi could POST it and wipe a DJ's playlists — so it is
        // gated exactly like the other mutations, never as a "read" (риск 14).
        "/api/playlist/sync",
        "/api/playlist/sync/status",
        // Обновление агента по запросу с телефона. Неаутентифицированный POST сюда —
        // это «любой в кафейном Wi-Fi может в любой момент перезапустить твой агент
        // посреди сета» (и заставить его качать zip). Подпись обновления это не
        // защищает: она гарантирует, ЧТО поставится, но не КТО это инициировал.
        "/api/agent/update",
        "/api/agent/update/status",
    ]

    /// True when a request to `path` must be authorised (PSK, JWT, or trusted
    /// in-process origin). The router skips the gate only for public endpoints
    /// (pairing handshake, status, similar, analysis reads).
    static func requiresAuth(path: String) -> Bool {
        dataProtectedPaths.contains(path) || controlProtectedPaths.contains(path)
    }

    /// Pure authorization core shared by the live `authGate`. Order:
    ///  1. A valid per-device PSK authorises a local (LAN) client.
    ///  2. No named tunnel (audience empty) ⇒ **DENY** (task 6001 fix). Without a
    ///     named tunnel the server signs no JWT, so the PSK is the only trusted
    ///     remote credential; a request lacking it must be refused, never waved
    ///     through. This is the single line that turns fail-open into fail-closed.
    ///  3. On a named tunnel, allow iff the server JWT validates.
    static func decide(
        lanSecret: String,
        providedToken: String?,
        namedHostname: String,
        jwtToken: String?,
        validate: (_ token: String?, _ audience: String) -> JWTValidator.Failure?
    ) -> AccessDecision {
        if !lanSecret.isEmpty, let provided = providedToken, !provided.isEmpty,
           constantTimeEquals(provided, lanSecret) {
            return .allow
        }
        // 6001: fail closed. Was `return .allow` (open) when the audience was empty.
        guard !namedHostname.isEmpty else { return .deny }
        return validate(jwtToken, namedHostname) == nil ? .allow : .deny
    }

    /// Constant-time comparison so PSK verification does not leak length/prefix via
    /// response timing. Returns true only when both byte sequences are identical.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        var diff = UInt8(ab.count == bb.count ? 0 : 1)
        let n = max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= (x ^ y)
            i += 1
        }
        return diff == 0
    }
}

// MARK: - CORS (6003: no wildcard Access-Control-Allow-Origin)

enum CORSPolicy {
    /// Browsers that legitimately talk to the agent cross-origin: only the Rimeo
    /// web player. Native iOS / relay clients are not browsers and need no CORS at
    /// all. A wildcard "*" let ANY page the user opened fetch /api/data & /stream.
    static let allowedOrigins: Set<String> = [
        "https://rimeo.app",
        "https://www.rimeo.app",
    ]

    static func isAllowed(origin: String?) -> Bool {
        guard let origin = origin, !origin.isEmpty else { return false }
        return allowedOrigins.contains(origin)
    }

    /// CORS response headers for a given request Origin. Empty when the origin is
    /// not on the allow-list → the browser blocks the cross-origin read AND the
    /// pre-flight for a state-changing request fails, so it is never sent.
    static func headers(forOrigin origin: String?) -> [String: String] {
        guard isAllowed(origin: origin), let origin = origin else { return [:] }
        return [
            "Access-Control-Allow-Origin":  origin,
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Authorization, Content-Type, Range",
            "Vary":                         "Origin",
        ]
    }
}

// MARK: - Library path containment (6002: no arbitrary file read via ?path=)

enum LibraryPathGuard {
    private static let rootsLock = NSLock()
    private static var cachedRootsSignature = ""
    private static var cachedCanonicalRoots: [String] = []

    /// Canonical absolute path: resolve symlinks + `..` via realpath when the file
    /// exists, else fall back to a lexical standardization so a path on a
    /// not-yet-mounted volume is still stripped of `..` traversal.
    static func canonical(_ path: String) -> String {
        if let real = realpathResolve(path) { return real }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func realpathResolve(_ path: String) -> String? {
        path.withCString { cstr -> String? in
            guard let resolved = realpath(cstr, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Collapse a leading `/Users/<name>/` to `/Users/*/` so username drift between
    /// the exported library and the current macOS account cannot defeat
    /// containment. The resolver in APIRouter deliberately remaps
    /// `/Users/<old>/…` → the current $HOME, so roots and candidates must compare
    /// on a user-agnostic form.
    static func normalizeUser(_ path: String) -> String {
        let marker = "/Users/"
        guard path.hasPrefix(marker) else { return path }
        let rest = path.dropFirst(marker.count)
        guard let slash = rest.firstIndex(of: "/") else { return path }
        return "/Users/*/" + rest[rest.index(after: slash)...]
    }

    /// Pure containment over already-canonical inputs: is `candidate` inside one of
    /// `canonicalRoots`? Directory-prefix with a `/` boundary so root `/a/music`
    /// does NOT authorise `/a/music-secret`.
    static func isContainedCanonical(_ candidate: String, canonicalRoots: [String]) -> Bool {
        guard !candidate.isEmpty else { return false }
        for r in canonicalRoots {
            guard !r.isEmpty else { continue }
            if candidate == r { return true }
            let boundary = r.hasSuffix("/") ? r : r + "/"
            if candidate.hasPrefix(boundary) { return true }
        }
        return false
    }

    /// Test-facing: canonicalize the candidate and every root, then check containment.
    static func isContained(_ path: String, roots: [String]) -> Bool {
        isContainedCanonical(normalizeUser(canonical(path)),
                             canonicalRoots: roots.map { normalizeUser(canonical($0)) })
    }

    /// Directories that legitimately hold servable content: the parent folder of
    /// every library track, plus the agent's own cache (server-generated audio
    /// derivatives) and the Rekordbox share/db dir (cover art). Rebuilt from the
    /// (cached) parsed library on each call.
    static func allowedRoots() -> [String] {
        var roots = Set<String>()
        for track in RekordboxParser.shared.parse().tracks {
            let loc = track.location
            guard !loc.isEmpty else { continue }
            let dir = (loc as NSString).deletingLastPathComponent
            if !dir.isEmpty, dir != "/" { roots.insert(dir) }
        }
        // Agent-managed dirs: converted 16-bit/AIFF WAVs and extracted artwork.
        roots.insert(AppConfig.shared.cacheDir.path)
        let db = AppConfig.shared.dbPath
        if !db.isEmpty {
            let rbDir = (db as NSString).deletingLastPathComponent
            if !rbDir.isEmpty, rbDir != "/" {
                roots.insert(rbDir)
                roots.insert((rbDir as NSString).appendingPathComponent("share"))
            }
        }
        return Array(roots)
    }

    /// Canonicalized roots, memoized on a cheap library signature so the hot
    /// streaming path does not realpath every root on every (range) request — which
    /// on a large library over a slow external volume would add real latency.
    private static func canonicalAllowedRoots() -> [String] {
        let tracks = RekordboxParser.shared.parse().tracks
        let signature = "\(tracks.count)|\(tracks.first?.location ?? "")|\(tracks.last?.location ?? "")"
        rootsLock.lock(); defer { rootsLock.unlock() }
        if signature == cachedRootsSignature, !cachedCanonicalRoots.isEmpty {
            return cachedCanonicalRoots
        }
        let canon = allowedRoots().map { normalizeUser(canonical($0)) }
        cachedRootsSignature = signature
        cachedCanonicalRoots = canon
        return canon
    }

    /// The check the file endpoints call. Empty path or empty library ⇒ nothing is
    /// servable ⇒ deny.
    static func isAllowed(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return isContainedCanonical(normalizeUser(canonical(path)),
                                    canonicalRoots: canonicalAllowedRoots())
    }
}

// MARK: - Auto-update signature verification (6005: no unsigned RCE)

enum UpdateSignatureError: LocalizedError {
    case codesignFailed(String)
    case teamMismatch(String)
    case unsafePath(String)
    case missingSignature(String)
    case badSignature

    var errorDescription: String? {
        switch self {
        case .codesignFailed(let s):   return "Update signature invalid: \(s)"
        case .teamMismatch(let s):     return "Update signed by an untrusted team: \(s)"
        case .unsafePath(let s):       return "Refusing unsafe update path: \(s)"
        case .missingSignature(let s): return "Update signature file missing: \(s)"
        case .badSignature:            return "Update archive signature is invalid"
        }
    }
}

enum UpdateSignatureVerifier {
    /// The only Team ID whose Developer ID Application signature we accept for a
    /// self-update (see build_local_mac.sh — "team MM3Q8TJL85"). An update signed
    /// by anyone else, or unsigned, is refused BEFORE the running bundle is
    /// replaced — a compromised GitHub release cannot ship our signature.
    static let expectedTeamID = "MM3Q8TJL85"

    /// Detached-signature public key (contents of update_pub.pem, PKIX/SPKI). The
    /// matching private key lives ONLY in release CI (secret UPDATE_SIGNING_KEY) and
    /// signs `update.zip` → `update.zip.sig`. Same key on macOS and Windows, so one
    /// signature verifies identically everywhere. A compromised GitHub release can
    /// serve a zip but cannot produce a valid .sig without this private key.
    static let updatePublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE13+tB8Bq9f/Hi7ez4nff0roiRz4E
    LGxTQT37N0MMd+jwfqh4P+vmK4oMBsrvwhxkIRB60rgWcVbr8irPMYJLEw==
    -----END PUBLIC KEY-----
    """

    /// Verify an update archive against its detached ECDSA-P256 / SHA-256 (DER)
    /// signature using the baked update public key. Produced by
    /// `openssl dgst -sha256 -sign update_priv.pem`. Throws (fail-CLOSED) when the
    /// .sig is absent or does not verify — the caller MUST NOT apply on throw.
    static func verifyZipSignature(zipPath: String, sigPath: String) throws {
        try verifyZipSignature(zipPath: zipPath, sigPath: sigPath, publicKeyPEM: updatePublicKeyPEM)
    }

    /// Injectable-key overload for unit tests.
    static func verifyZipSignature(zipPath: String, sigPath: String, publicKeyPEM: String) throws {
        guard FileManager.default.fileExists(atPath: sigPath) else {
            throw UpdateSignatureError.missingSignature(sigPath)
        }
        let sigData = try Data(contentsOf: URL(fileURLWithPath: sigPath))
        guard let pubKey = try? P256.Signing.PublicKey(
                pemRepresentation: publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: sigData) else {
            throw UpdateSignatureError.badSignature
        }
        let digest = try sha256OfFile(zipPath)
        guard pubKey.isValidSignature(signature, for: digest) else {
            throw UpdateSignatureError.badSignature
        }
    }

    private static func sha256OfFile(_ path: String) throws -> SHA256.Digest {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            throw UpdateSignatureError.missingSignature(path)
        }
        defer { try? fh.close() }
        var hasher = SHA256()
        while case let chunk = fh.readData(ofLength: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    static func teamIDMatches(_ actual: String?, expected: String) -> Bool {
        guard let actual = actual?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actual.isEmpty else { return false }
        return actual == expected
    }

    /// Reject paths carrying shell metacharacters before they ever reach the
    /// osascript `do shell script` privileged-replace fallback (defense in depth
    /// against command injection through a crafted .app name inside the archive).
    static func isSafeShellPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let forbidden: Set<Character> = ["'", "\"", "`", "$", "\\", "\n", "\r",
                                         ";", "&", "|", "<", ">", "(", ")"]
        return !path.contains(where: { forbidden.contains($0) })
    }

    /// Extract `TeamIdentifier=` from `codesign -dv --verbose=4` output. Returns
    /// nil for an ad-hoc / unsigned bundle ("TeamIdentifier=not set").
    static func parseTeamID(fromCodesignOutput out: String) -> String? {
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TeamIdentifier=") {
                let v = String(trimmed.dropFirst("TeamIdentifier=".count))
                    .trimmingCharacters(in: .whitespaces)
                return (v.isEmpty || v == "not set") ? nil : v
            }
        }
        return nil
    }

    /// Verify a downloaded/extracted `.app`: structural signature integrity
    /// (codesign --verify --deep --strict) AND our Team ID. Throws (fail-closed)
    /// on any failure; the caller MUST NOT replace the running bundle on throw.
    static func verify(appPath: String) throws {
        let verify = runProcess("/usr/bin/codesign",
                                ["--verify", "--deep", "--strict", appPath])
        guard verify.status == 0 else {
            throw UpdateSignatureError.codesignFailed(
                verify.err.isEmpty ? "codesign --verify exited \(verify.status)" : verify.err)
        }
        let info = runProcess("/usr/bin/codesign", ["-dv", "--verbose=4", appPath])
        // codesign writes the signing info to stderr.
        let combined = info.err.isEmpty ? info.out : info.err
        let team = parseTeamID(fromCodesignOutput: combined)
        guard teamIDMatches(team, expected: expectedTeamID) else {
            throw UpdateSignatureError.teamMismatch(team ?? "(unsigned)")
        }
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, _ args: [String])
        -> (status: Int32, out: String, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return (-1, "", "\(error)") }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }
}

// MARK: - Helper-binary download host pinning (6006)

enum ComponentHostPolicy {
    /// Hosts we accept helper-binary (cloudflared / ffmpeg / ffprobe) downloads
    /// from. The manifest is served by rimeo.app; the binaries live on rimeo.app
    /// or its GitHub-releases CDN. Pinning the host means a compromised manifest
    /// cannot redirect the download to an attacker server to drop an executable.
    static let allowedHosts: Set<String> = [
        "rimeo.app", "www.rimeo.app",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    static func isAllowed(urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }
}
