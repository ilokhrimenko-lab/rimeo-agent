import Foundation
import CryptoKit

// ES256 (ECDSA P-256 + SHA-256) JWT validator for protected endpoints
// exposed to the public internet through the named tunnel.
//
// Server-side signer is rimeo_webapp/jwt_signer.py (П3).
// Claims used here: aud (== this agent's tunnel hostname), exp.
//
// Public key is baked into the binary at release time. While the placeholder
// below is empty the validator no-ops and the agent stays usable for dev /
// quick-tunnel builds (graceful degrade — server also degrades when keys are
// not provisioned). П7 (agent_min_build gating) ensures clients only target
// agents whose build matches their authentication mode.
enum JWTValidator {
    // Contents of jwt_public.pem produced by tools/gen_jwt_keys.py
    // (SubjectPublicKeyInfo / PKIX PEM). The matching private key lives only in
    // the rimeo.app server env (JWT_PRIVATE_KEY_PEM / _PATH). Enforcement is
    // additionally gated to named-tunnel mode in APIRouter.jwtGate, so this key
    // stays inert while the agent is still on a quick tunnel.
    static let publicKeyPEM: String = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUiawXlrjeQhLWfXjgs9FiuHjqOMt
    h0XfbBreh55YjgoyMsGys7emSXv3pBlUOeYWXGM3y+ZCiSPYuZNyHLWu2w==
    -----END PUBLIC KEY-----
    """

    enum Failure: String {
        case missing
        case malformed
        case wrongAlgorithm
        case expired
        case wrongAudience
        case invalidSignature
        case notConfigured

        var status: Int { self == .missing ? 401 : 401 }
    }

    private static let clockSkewSeconds: TimeInterval = 60
    private static let logLock = NSLock()
    private static var loggedNotConfigured = false

    static func isConfigured() -> Bool {
        !publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func validate(token rawToken: String?, expectedAudience: String) -> Failure? {
        guard isConfigured() else {
            logLock.lock()
            let shouldLog = !loggedNotConfigured
            loggedNotConfigured = true
            logLock.unlock()
            if shouldLog {
                logger.warning("JWT validation disabled: public key not configured (dev build / pre-rollout)")
            }
            return nil
        }
        guard expectedAudience.isEmpty == false else {
            // Named tunnel hostname unknown — refuse rather than trust a
            // token that may have been signed for a different agent.
            return .wrongAudience
        }
        guard let token = rawToken, !token.isEmpty else { return .missing }

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .malformed }
        let headerB64  = String(parts[0])
        let payloadB64 = String(parts[1])
        let sigB64     = String(parts[2])

        guard let headerData  = base64URLDecode(headerB64),
              let payloadData = base64URLDecode(payloadB64),
              let sigData     = base64URLDecode(sigB64) else { return .malformed }

        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let alg = header["alg"] as? String else { return .malformed }
        if alg != "ES256" { return .wrongAlgorithm }

        guard let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            return .malformed
        }

        let expValue: Double?
        if let n = payload["exp"] as? Double { expValue = n }
        else if let n = payload["exp"] as? Int { expValue = Double(n) }
        else if let s = payload["exp"] as? String, let n = Double(s) { expValue = n }
        else { expValue = nil }
        guard let exp = expValue else { return .malformed }
        if Date().timeIntervalSince1970 > exp + clockSkewSeconds { return .expired }

        guard let aud = payload["aud"] as? String, !aud.isEmpty else { return .wrongAudience }
        if !audienceMatches(aud, expected: expectedAudience) { return .wrongAudience }

        let trimmedPEM = publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pubKey = try? P256.Signing.PublicKey(pemRepresentation: trimmedPEM) else {
            return .notConfigured
        }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sigData) else {
            return .invalidSignature
        }
        let signingInput = Data((headerB64 + "." + payloadB64).utf8)
        let digest = SHA256.hash(data: signingInput)
        if !pubKey.isValidSignature(signature, for: digest) {
            return .invalidSignature
        }
        return nil
    }

    static func extractToken(from req: HTTPRequest) -> String? {
        if let q = req.queryParams["token"], !q.isEmpty { return q }
        if let auth = req.headers["authorization"], !auth.isEmpty {
            let lower = auth.lowercased()
            if lower.hasPrefix("bearer ") {
                return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            return auth
        }
        return nil
    }

    private static func audienceMatches(_ aud: String, expected: String) -> Bool {
        if aud == expected { return true }
        // Tolerate scheme/host shapes: token may carry the bare hostname while
        // expected may be derived from a URL ("https://host"), or vice versa.
        let a = stripScheme(aud)
        let e = stripScheme(expected)
        return !a.isEmpty && a == e
    }

    private static func stripScheme(_ s: String) -> String {
        var v = s
        for prefix in ["https://", "http://"] {
            if v.hasPrefix(prefix) { v = String(v.dropFirst(prefix.count)) }
        }
        if let slash = v.firstIndex(of: "/") { v = String(v[..<slash]) }
        return v
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem > 0 { str += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: str)
    }
}
