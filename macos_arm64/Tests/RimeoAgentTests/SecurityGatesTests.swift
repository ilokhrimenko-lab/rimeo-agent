import XCTest
@testable import RimeoAgent

/// Security-audit regression tests (tasks 6001–6006). Each fix has at least one
/// EXPLOIT case (passed before the fix, must now be blocked) and one LEGIT case
/// (must keep working). Run: `swift test --filter SecurityGatesTests`.
final class SecurityGatesTests: XCTestCase {

    // Helper: a JWT validator stub that "accepts" a specific token+audience pair.
    private func validatorStub(accept token: String, audience: String)
        -> (String?, String) -> JWTValidator.Failure? {
        return { t, a in (t == token && a == audience) ? nil : .invalidSignature }
    }
    private let alwaysReject: (String?, String) -> JWTValidator.Failure? = { _, _ in .invalidSignature }

    // ─────────────────────────────────────────────────────────────────────────
    // 6001 — jwtGate fail-open → fail-closed (AccessControl.decide)
    // ─────────────────────────────────────────────────────────────────────────

    func test_6001_exploit_noCredentials_noNamedTunnel_isDenied() {
        // Attacker hits /stream with NO PSK while the agent is on a quick tunnel
        // (namedHostname == ""). Before the fix this returned .allow (fail-open).
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: nil, transport: .lan,
            namedHostname: "", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    func test_6001_exploit_wrongPSK_noNamedTunnel_isDenied() {
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: "guessed-wrong", transport: .lan,
            namedHostname: "", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    func test_6001_exploit_emptySecret_anyToken_noTunnel_isDenied() {
        // No PSK provisioned at all + quick tunnel: still denied (was open).
        let d = AccessControl.decide(
            lanSecret: "", providedToken: "anything", transport: .lan,
            namedHostname: "", jwtToken: "anything", validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    func test_6001_legit_validPSK_onLAN_isAllowed() {
        // Paired iOS device presenting its PSK on the LAN (no tunnel needed).
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: "device-psk-abc", transport: .lan,
            namedHostname: "", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .allow)
    }

    func test_6001_legit_namedTunnel_validJWT_isAllowed() {
        // Remote client on the named tunnel with a server-signed JWT.
        let d = AccessControl.decide(
            lanSecret: "", providedToken: nil, transport: .lan,
            namedHostname: "abc.agent.rimeo.app", jwtToken: "good-token",
            validate: validatorStub(accept: "good-token", audience: "abc.agent.rimeo.app"))
        XCTAssertEqual(d, .allow)
    }

    func test_6001_namedTunnel_invalidJWT_isDenied() {
        let d = AccessControl.decide(
            lanSecret: "", providedToken: nil, transport: .lan,
            namedHostname: "abc.agent.rimeo.app", jwtToken: "forged",
            validate: validatorStub(accept: "good-token", audience: "abc.agent.rimeo.app"))
        XCTAssertEqual(d, .deny)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // LAN-auth v2, шаг 1 (2026-09-21): PSK действует только из LAN и с этой машины.
    // Утёкший PSK не должен давать удалённый доступ через публичный туннель/relay.
    // ─────────────────────────────────────────────────────────────────────────

    func test_lanAuth_pskAcceptedOnlyOnLANAndLocal() {
        XCTAssertTrue(AccessControl.acceptsPSK(transport: .lan))
        XCTAssertTrue(AccessControl.acceptsPSK(transport: .local))
        XCTAssertFalse(AccessControl.acceptsPSK(transport: .tunnel))
        XCTAssertFalse(AccessControl.acceptsPSK(transport: .relay))
        XCTAssertFalse(AccessControl.acceptsPSK(transport: .external))
        XCTAssertFalse(AccessControl.acceptsPSK(transport: .ui))
    }

    func test_lanAuth_exploit_validPSK_viaTunnel_isDenied() {
        // Утёкший PSK через публичный туннель: раньше .allow — вечный удалённый ключ.
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: "device-psk-abc", transport: .tunnel,
            namedHostname: "abc.agent.rimeo.app", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    func test_lanAuth_exploit_validPSK_viaRelay_isDenied() {
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: "device-psk-abc", transport: .relay,
            namedHostname: "abc.agent.rimeo.app", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    func test_lanAuth_exploit_validPSK_fromPublicIP_noTunnel_isDenied() {
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: "device-psk-abc", transport: .external,
            namedHostname: "", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    func test_lanAuth_legit_validPSK_sameMachine_isAllowed() {
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: "device-psk-abc", transport: .local,
            namedHostname: "", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .allow)
    }

    func test_lanAuth_legit_JWT_viaTunnelAndRelay_stillAllowed() {
        // Облако и веб-плеер ходят через туннель/relay с JWT — это не должно сломаться.
        for t in [Transport.tunnel, .relay] {
            let d = AccessControl.decide(
                lanSecret: "device-psk-abc", providedToken: nil, transport: t,
                namedHostname: "abc.agent.rimeo.app", jwtToken: "good-token",
                validate: validatorStub(accept: "good-token", audience: "abc.agent.rimeo.app"))
            XCTAssertEqual(d, .allow, "JWT via \(t.rawValue) must keep working")
        }
    }

    func test_lanAuth_tunnelDetection_needsLoopbackPeer() {
        // Туннель распознаётся только у loopback-пира. Сосед по Wi-Fi, приславший
        // себе cf-ray, остаётся LAN: подделать канал «туннель» он не может.
        XCTAssertEqual(Transport.classify(peerIP: "127.0.0.1", headers: ["cf-ray": "x"]), .tunnel)
        XCTAssertEqual(Transport.classify(peerIP: "127.0.0.1", headers: [:]), .local)
        XCTAssertEqual(Transport.classify(peerIP: "192.168.1.50", headers: ["cf-ray": "x"]), .lan)
        XCTAssertEqual(Transport.classify(peerIP: "8.8.8.8", headers: [:]), .external)
    }

    /// Связка req.transport → authGate на настоящем роутере: верный PSK с loopback-пира
    /// с CF-заголовками (так выглядит запрос через туннель) → 401, и ответ не выдаёт, что
    /// ключ верный. Нужен PSK этой машины; на машине без него тест пропускается.
    func test_lanAuth_http_validPSK_viaTunnel_is401_withoutOracle() throws {
        let psk = DataStore.shared.data.lan_secret
        try XCTSkipIf(psk.isEmpty, "на этой машине нет lan_secret")
        let tunnel = APIRouter.shared.route(HTTPRequest(
            method: "GET", path: "/api/logs",
            queryParams: ["lan_token": psk],
            headers: ["cf-ray": "x", "cf-connecting-ip": "203.0.113.7"],
            body: Data(), trusted: false, peerIP: "127.0.0.1"))
        XCTAssertEqual(tunnel.status, 401, "PSK через туннель не должен пускать")
        let wrong = APIRouter.shared.route(HTTPRequest(
            method: "GET", path: "/api/logs",
            queryParams: ["lan_token": "definitely-wrong"],
            headers: ["cf-ray": "x", "cf-connecting-ip": "203.0.113.7"],
            body: Data(), trusted: false, peerIP: "127.0.0.1"))
        XCTAssertEqual(wrong.status, 401)
        XCTAssertEqual(tunnel.headers["WWW-Authenticate"], wrong.headers["WWW-Authenticate"],
                       "ответ на верный и неверный ключ через туннель должен быть одинаковым")
    }

    func test_lanAuth_isValidPSK_emptySecretNeverMatches() {
        XCTAssertFalse(AccessControl.isValidPSK(lanSecret: "", providedToken: ""))
        XCTAssertFalse(AccessControl.isValidPSK(lanSecret: "", providedToken: nil))
        XCTAssertFalse(AccessControl.isValidPSK(lanSecret: "abc", providedToken: nil))
        XCTAssertTrue(AccessControl.isValidPSK(lanSecret: "abc", providedToken: "abc"))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6004 — control/mutating endpoints must require auth
    // ─────────────────────────────────────────────────────────────────────────

    func test_6004_controlEndpoints_requireAuth() {
        for p in ["/reveal", "/api/link_account", "/api/unlink_account",
                  "/api/agent_login", "/api/agent_signup", "/api/tunnel/start",
                  "/api/tunnel/stop", "/api/send_tg", "/api/save_note",
                  "/api/save_exclusions", "/api/rename_history", "/api/report_bug"] {
            XCTAssertTrue(AccessControl.requiresAuth(path: p), "\(p) must be gated")
        }
    }

    func test_6004_publicHandshakeEndpoints_areNotGated() {
        // These stay reachable without the PSK/JWT gate. `/api/pairing_info` is here
        // too — but its HANDLER enforces req.trusted (see the C1 tests below), because
        // the endpoint that hands out the PSK cannot be protected by a PSK gate.
        for p in ["/api/pairing_info", "/api/check_pairing", "/api/status",
                  "/api/account", "/api/similar", "/api/tunnel/status",
                  "/api/playlist/recommendations"] {
            XCTAssertFalse(AccessControl.requiresAuth(path: p), "\(p) must stay public")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // C1 / default-deny — the auth gate is now an allow-list (requiresAuth == !public)
    // ─────────────────────────────────────────────────────────────────────────

    func test_defaultDeny_unknownRoute_requiresAuth() {
        // A route nobody classified (e.g. added later) must be protected BY DEFAULT,
        // never silently world-readable. This is the tripwire for the C1/M1/M4/M11
        // root cause (opt-in "default-open" authorization).
        for p in ["/api/some_new_route", "/api/whatever", "/totally/unknown", "/"] {
            XCTAssertTrue(AccessControl.requiresAuth(path: p), "\(p) must default to gated")
        }
    }

    func test_M4_analysisWriteEndpoints_requireAuth() {
        // Unauthenticated POST /api/analysis/start kicked off a full-library ffmpeg
        // job (CPU/DoS). start/stop/recheck are now gated; the reads stay public.
        for p in ["/api/analysis/start", "/api/analysis/stop", "/api/analysis/recheck"] {
            XCTAssertTrue(AccessControl.requiresAuth(path: p), "\(p) must be gated (M4)")
        }
        for p in ["/api/analysis", "/api/analysis/status", "/api/analysis/track_list"] {
            XCTAssertFalse(AccessControl.requiresAuth(path: p), "\(p) read stays public")
        }
    }

    func test_M1_adminDiag_requiresAuth() {
        // /api/admin/diag leaked absolute on-disk paths + the tunnel URL to anyone.
        XCTAssertTrue(AccessControl.requiresAuth(path: "/api/admin/diag"),
                      "admin/diag must be gated (M1)")
    }

    func test_C1_pairingInfo_overSocket_isForbidden() {
        // The critical one: a NETWORK request (trusted == false, as every socket
        // request is) must NOT receive the master PSK. The gate is skipped for
        // pairing_info, so the handler's req.trusted guard is what stops the leak.
        let resp = APIRouter.shared.route(HTTPRequest(
            method: "GET", path: "/api/pairing_info",
            queryParams: [:], headers: [:], body: Data(), trusted: false))
        XCTAssertEqual(resp.status, 403, "pairing_info must be 403 over a socket")
    }

    func test_C1_pairingInfo_viaTunnelFromLoopback_isForbidden() {
        // Регресс-пин по Windows-дыре 2026-09-21: cloudflared и CloudRelay ходят с
        // 127.0.0.1, поэтому гейт «пир — loopback» пускал интернет через туннель.
        // На macOS гейт — req.trusted (только in-process UI), loopback-пир не помогает.
        for headers in [["cf-ray": "x", "cf-connecting-ip": "203.0.113.7"], [:]] {
            let resp = APIRouter.shared.route(HTTPRequest(
                method: "GET", path: "/api/pairing_info",
                queryParams: [:], headers: headers, body: Data(), trusted: false,
                peerIP: "127.0.0.1"))
            XCTAssertEqual(resp.status, 403, "pairing_info must be 403 for a loopback peer \(headers)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // M5 — cloud_url pinning (no PSK exfil / SSRF to an attacker host)
    // ─────────────────────────────────────────────────────────────────────────

    func test_M5_cloudURLPolicy_pinsToRimeoHTTPS() {
        XCTAssertTrue(CloudURLPolicy.isAllowed("https://rimeo.app"))
        XCTAssertTrue(CloudURLPolicy.isAllowed("https://www.rimeo.app/api/agents/link"))
        XCTAssertFalse(CloudURLPolicy.isAllowed("http://rimeo.app"))            // not https
        XCTAssertFalse(CloudURLPolicy.isAllowed("https://evil.example"))        // off-list host
        XCTAssertFalse(CloudURLPolicy.isAllowed("https://rimeo.app.evil.com"))  // suffix trick
        XCTAssertFalse(CloudURLPolicy.isAllowed(""))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NEW-3 — tunnel_id / hostname validation (YAML injection + path traversal)
    // ─────────────────────────────────────────────────────────────────────────

    func test_NEW3_tunnelID_rejectsTraversalAndNonHex() {
        XCTAssertTrue(TunnelProvisioner.isSafeTunnelID("a1b2c3d4-5678-90ab-cdef-1234567890ab"))
        XCTAssertFalse(TunnelProvisioner.isSafeTunnelID("../../etc/passwd"))  // path traversal
        XCTAssertFalse(TunnelProvisioner.isSafeTunnelID("id with space"))
        XCTAssertFalse(TunnelProvisioner.isSafeTunnelID("short"))             // < 8 chars
        XCTAssertFalse(TunnelProvisioner.isSafeTunnelID("zzzzzzzz"))          // non-hex
    }

    func test_NEW3_hostname_rejectsNewlineAndColon() {
        XCTAssertTrue(TunnelProvisioner.isSafeHostname("abc.agent.rimeo.app"))
        XCTAssertFalse(TunnelProvisioner.isSafeHostname("evil\ningress: bad"))  // YAML injection
        XCTAssertFalse(TunnelProvisioner.isSafeHostname("host with space"))
        XCTAssertFalse(TunnelProvisioner.isSafeHostname("http://x"))            // colon/slash
        XCTAssertFalse(TunnelProvisioner.isSafeHostname(""))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // M11 — strip on-disk `location` from public similar/recommendation results
    // ─────────────────────────────────────────────────────────────────────────

    func test_M11_stripsLocation_forUnauthorized_keepsMetadata() {
        let input: [[String: Any]] = [
            ["track": ["title": "T", "artist": "A", "location": "/Users/x/.ssh/id_rsa"],
             "score": ["total": 1.0]],
        ]
        // Unauthorized: the absolute path is removed, the metadata is kept.
        let stripped = APIRouter.shared.stripLocationsIfUnauthorized(input, authorized: false)
        let strippedTrack = (stripped as? [[String: Any]])?.first?["track"] as? [String: Any]
        XCTAssertNil(strippedTrack?["location"], "location must be stripped for unauth")
        XCTAssertEqual(strippedTrack?["title"] as? String, "T", "metadata must be kept")
        // Authorized: untouched (the paired iOS app needs location to stream).
        let kept = APIRouter.shared.stripLocationsIfUnauthorized(input, authorized: true)
        let keptTrack = (kept as? [[String: Any]])?.first?["track"] as? [String: Any]
        XCTAssertEqual(keptTrack?["location"] as? String, "/Users/x/.ssh/id_rsa")
    }

    func test_6004_playlistMutations_requireAuth() {
        for p in ["/api/playlist/create", "/api/playlist/create_folder",
                  "/api/playlist/add", "/api/playlist/remove",
                  "/api/playlist/reorder", "/api/playlist/rename",
                  "/api/playlist/delete", "/api/playlist/sync"] {
            XCTAssertTrue(AccessControl.requiresAuth(path: p), "\(p) must be gated")
        }
    }

    // Фаза 6, риск 14. /api/playlist/sync is the only endpoint that writes the
    // user's real Rekordbox master.db — it can create, rename and DELETE playlists
    // in a library that is not backed up anywhere else. Ungated, anyone on the same
    // Wi-Fi could POST it. This assertion is the tripwire: it fails the build if the
    // path is ever dropped from controlProtectedPaths.
    func test_6004_playlistSync_isGated_evenWithoutCredentials() {
        XCTAssertTrue(AccessControl.requiresAuth(path: "/api/playlist/sync"))
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: nil, transport: .lan,
            namedHostname: "", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    func test_6004_exploit_linkAccountTakeover_noCreds_isDenied() {
        // POST /api/link_account with an attacker token, no PSK, quick tunnel.
        XCTAssertTrue(AccessControl.requiresAuth(path: "/api/link_account"))
        let d = AccessControl.decide(
            lanSecret: "device-psk-abc", providedToken: nil, transport: .lan,
            namedHostname: "", jwtToken: nil, validate: alwaysReject)
        XCTAssertEqual(d, .deny)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6003 — CORS "*" removed → explicit origin allow-list
    // ─────────────────────────────────────────────────────────────────────────

    func test_6003_exploit_arbitraryOrigin_getsNoCORS() {
        XCTAssertFalse(CORSPolicy.isAllowed(origin: "https://evil.example"))
        XCTAssertTrue(CORSPolicy.headers(forOrigin: "https://evil.example").isEmpty)
        XCTAssertTrue(CORSPolicy.headers(forOrigin: nil).isEmpty)
        XCTAssertTrue(CORSPolicy.headers(forOrigin: "").isEmpty)
    }

    func test_6003_neverEmitsWildcard() {
        for origin in ["https://rimeo.app", "https://evil.example", "null", ""] {
            let acao = CORSPolicy.headers(forOrigin: origin)["Access-Control-Allow-Origin"]
            XCTAssertNotEqual(acao, "*")
        }
    }

    func test_6003_legit_rimeoOrigin_isReflected() {
        let h = CORSPolicy.headers(forOrigin: "https://rimeo.app")
        XCTAssertEqual(h["Access-Control-Allow-Origin"], "https://rimeo.app")
        XCTAssertEqual(h["Vary"], "Origin")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6002 — arbitrary file read via ?path= → library-root containment
    // ─────────────────────────────────────────────────────────────────────────

    private func makeTempTree() throws -> (root: String, musicDir: String, track: String, secret: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_sec_\(UUID().uuidString)")
        let music = base.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let track  = music.appendingPathComponent("track.mp3")
        let secret = base.appendingPathComponent("secret.txt")   // sibling of music/
        try Data("audio".utf8).write(to: track)
        try Data("TOP SECRET".utf8).write(to: secret)
        return (base.path, music.path, track.path, secret.path)
    }

    func test_6002_legit_libraryTrack_isAllowed() throws {
        let t = try makeTempTree()
        XCTAssertTrue(LibraryPathGuard.isContained(t.track, roots: [t.musicDir]))
    }

    func test_6002_exploit_dotDotTraversal_isDenied() throws {
        let t = try makeTempTree()
        // /…/music/../secret.txt canonicalizes OUT of the music root.
        let traversal = t.musicDir + "/../secret.txt"
        XCTAssertFalse(LibraryPathGuard.isContained(traversal, roots: [t.musicDir]))
    }

    func test_6002_exploit_absoluteOutsidePath_isDenied() throws {
        let t = try makeTempTree()
        XCTAssertFalse(LibraryPathGuard.isContained("/etc/passwd", roots: [t.musicDir]))
        XCTAssertFalse(LibraryPathGuard.isContained(t.secret, roots: [t.musicDir]))
    }

    func test_6002_exploit_symlinkEscape_isDenied() throws {
        let t = try makeTempTree()
        // A symlink inside the music root pointing at the secret outside it.
        let link = t.musicDir + "/cover.jpg"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: t.secret)
        XCTAssertFalse(LibraryPathGuard.isContained(link, roots: [t.musicDir]))
    }

    func test_6002_exploit_siblingPrefix_isDenied() throws {
        // Root "…/music" must NOT authorise "…/music-private/x" (boundary check).
        let t = try makeTempTree()
        let sibling = t.root + "/music-private/x.mp3"
        XCTAssertFalse(LibraryPathGuard.isContained(sibling, roots: [t.musicDir]))
    }

    func test_6002_legit_usernameDrift_isAllowed() {
        // Library exported under /Users/olduser, agent runs as /Users/newuser.
        // (Paths need not exist — the lexical /Users/*/ collapse handles drift.)
        XCTAssertTrue(LibraryPathGuard.isContained(
            "/Users/newuser/Music/Rekordbox/track.mp3",
            roots: ["/Users/olduser/Music/Rekordbox"]))
        XCTAssertFalse(LibraryPathGuard.isContained(
            "/Users/newuser/.ssh/id_rsa",
            roots: ["/Users/olduser/Music/Rekordbox"]))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6005 — auto-update signature verification (Team ID + codesign)
    // ─────────────────────────────────────────────────────────────────────────

    func test_6005_teamIDMatch() {
        XCTAssertTrue(UpdateSignatureVerifier.teamIDMatches("MM3Q8TJL85", expected: "MM3Q8TJL85"))
        XCTAssertFalse(UpdateSignatureVerifier.teamIDMatches("APPLE12345", expected: "MM3Q8TJL85"))
        XCTAssertFalse(UpdateSignatureVerifier.teamIDMatches(nil, expected: "MM3Q8TJL85"))
        XCTAssertFalse(UpdateSignatureVerifier.teamIDMatches("", expected: "MM3Q8TJL85"))
    }

    func test_6005_isSafeShellPath_blocksInjection() {
        XCTAssertTrue(UpdateSignatureVerifier.isSafeShellPath("/Applications/Rimeo Desktop Agent.app"))
        XCTAssertFalse(UpdateSignatureVerifier.isSafeShellPath("/tmp/x'; rm -rf ~ #.app"))
        XCTAssertFalse(UpdateSignatureVerifier.isSafeShellPath("/tmp/$(whoami).app"))
        XCTAssertFalse(UpdateSignatureVerifier.isSafeShellPath("/tmp/`id`.app"))
        XCTAssertFalse(UpdateSignatureVerifier.isSafeShellPath(""))
    }

    func test_6005_parseTeamID() {
        let out = "Identifier=app.rimeo.agent\nFormat=app bundle\nTeamIdentifier=MM3Q8TJL85\nSealed Resources=..."
        XCTAssertEqual(UpdateSignatureVerifier.parseTeamID(fromCodesignOutput: out), "MM3Q8TJL85")
        XCTAssertNil(UpdateSignatureVerifier.parseTeamID(fromCodesignOutput: "TeamIdentifier=not set"))
        XCTAssertNil(UpdateSignatureVerifier.parseTeamID(fromCodesignOutput: "no team here"))
    }

    func test_6005_exploit_unsignedArtifact_isRejected() throws {
        // A fake .app with no signature: codesign --verify fails → verify() throws.
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("Evil_\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nrm -rf ~\n".utf8)
            .write(to: fake.appendingPathComponent("payload"))
        XCTAssertThrowsError(try UpdateSignatureVerifier.verify(appPath: fake.path))
    }

    func test_6005_exploit_wrongTeamSignedApp_isRejected() throws {
        // A validly-signed app from a DIFFERENT team (Apple) — models an attacker
        // shipping their OWN Developer-ID-signed .app. Must be rejected on Team ID.
        let candidates = ["/System/Applications/Calculator.app",
                          "/System/Applications/Chess.app",
                          "/System/Applications/TextEdit.app"]
        guard let signedApp = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("no system .app available to test wrong-team rejection")
        }
        XCTAssertThrowsError(try UpdateSignatureVerifier.verify(appPath: signedApp)) { error in
            // Rejected specifically because the Team ID isn't ours.
            guard case UpdateSignatureError.teamMismatch = error else {
                return XCTFail("expected teamMismatch, got \(error)")
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 6006 — JWTValidator fail-open + helper-binary host pinning
    // ─────────────────────────────────────────────────────────────────────────

    func test_6006_exploit_emptyKey_failsClosed() {
        // Before the fix an empty key returned nil (accept ANY token). Now it must
        // return a Failure (deny).
        let result = JWTValidator.validate(
            token: "aaa.bbb.ccc", expectedAudience: "abc.agent.rimeo.app", publicKeyPEM: "")
        XCTAssertNotNil(result, "empty key must NOT accept a token (fail-open)")
        XCTAssertEqual(result, .notConfigured)
    }

    func test_6006_legit_bakedKey_stillRejectsGarbage() {
        // With the real baked-in key, a garbage token is still rejected (not nil).
        let result = JWTValidator.validate(
            token: "garbage-token", expectedAudience: "abc.agent.rimeo.app",
            publicKeyPEM: JWTValidator.publicKeyPEM)
        XCTAssertNotNil(result)
    }

    func test_6006_componentHost_pinning() {
        XCTAssertTrue(ComponentHostPolicy.isAllowed(urlString: "https://rimeo.app/dl/cloudflared"))
        XCTAssertTrue(ComponentHostPolicy.isAllowed(urlString: "https://github.com/ilokhrimenko-lab/rimeo-agent/releases/download/x/ffmpeg"))
        XCTAssertFalse(ComponentHostPolicy.isAllowed(urlString: "https://evil.example/cloudflared"))
        XCTAssertFalse(ComponentHostPolicy.isAllowed(urlString: "http://rimeo.app/cloudflared")) // not https
        XCTAssertFalse(ComponentHostPolicy.isAllowed(urlString: "https://rimeo.app.evil.com/x"))  // suffix trick
    }
}
