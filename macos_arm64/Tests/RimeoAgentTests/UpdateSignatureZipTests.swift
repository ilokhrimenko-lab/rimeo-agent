import XCTest
@testable import RimeoAgent

/// 6005 — detached update-archive signature verification.
///
/// The fixture below is REAL: `payload` was signed with the production
/// update_priv.pem via `openssl dgst -sha256 -sign` (DER ECDSA-P256), and the
/// signature is verified here against the BAKED update_pub.pem. So this test
/// proves the exact CI-signing command and the in-agent verifier agree on the
/// format — the thing that silently breaks if either side drifts.
final class UpdateSignatureZipTests: XCTestCase {

    // Exact bytes signed by openssl (30 bytes, trailing newline included).
    private let payload = Data("RIMEO_UPDATE_TEST_ARTIFACT_v1\n".utf8)
    // Output of: openssl dgst -sha256 -sign update_priv.pem -out x.sig payload ; base64 x.sig
    private let sigBase64 = "MEYCIQD0JlrZzkFOv1e+s5e6gXeuUcVvNRnOSb0gW5pjchRsqgIhALOqurHO4XQX+IWnytNLP5peP/yFqq7SkvYpfQ5CVrrS"

    private func writeFixture() throws -> (zip: String, sig: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_upd_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        let sig = dir.appendingPathComponent("update.zip.sig")
        try payload.write(to: zip)
        try XCTUnwrap(Data(base64Encoded: sigBase64)).write(to: sig)
        return (zip.path, sig.path, dir)
    }

    func test_6005_bakedPublicKeyParses() throws {
        // A copy error in the baked PEM would surface here (and break all updates).
        XCTAssertTrue(UpdateSignatureVerifier.updatePublicKeyPEM.contains("BEGIN PUBLIC KEY"))
    }

    func test_6005_legit_validSignature_verifies() throws {
        let f = try writeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        // Must NOT throw: valid openssl signature against the baked key → update allowed.
        XCTAssertNoThrow(try UpdateSignatureVerifier.verifyZipSignature(zipPath: f.zip, sigPath: f.sig))
    }

    func test_6005_exploit_tamperedArchive_isRejected() throws {
        let f = try writeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        // Attacker swaps the archive but keeps the old (valid-looking) .sig.
        var tampered = payload
        tampered.append(contentsOf: [0x42])
        try tampered.write(to: URL(fileURLWithPath: f.zip))
        XCTAssertThrowsError(try UpdateSignatureVerifier.verifyZipSignature(zipPath: f.zip, sigPath: f.sig)) { error in
            guard case UpdateSignatureError.badSignature = error else {
                return XCTFail("expected badSignature, got \(error)")
            }
        }
    }

    func test_6005_exploit_missingSignature_isRejected() throws {
        let f = try writeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try FileManager.default.removeItem(atPath: f.sig)   // no .sig published
        XCTAssertThrowsError(try UpdateSignatureVerifier.verifyZipSignature(zipPath: f.zip, sigPath: f.sig)) { error in
            guard case UpdateSignatureError.missingSignature = error else {
                return XCTFail("expected missingSignature, got \(error)")
            }
        }
    }

    func test_6005_exploit_garbageSignature_isRejected() throws {
        let f = try writeFixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try Data("not a real signature".utf8).write(to: URL(fileURLWithPath: f.sig))
        XCTAssertThrowsError(try UpdateSignatureVerifier.verifyZipSignature(zipPath: f.zip, sigPath: f.sig))
    }
}
