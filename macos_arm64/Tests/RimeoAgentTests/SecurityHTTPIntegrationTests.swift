import XCTest
@testable import RimeoAgent

/// End-to-end verification over a real socket: boots the actual HTTPServer with
/// the live APIRouter and drives it with URLSession, so the FULL network path
/// (readRequest → route → authGate → CORS) is exercised — not just the pure core.
///
/// These are read-only: the 6001 case is rejected by authGate BEFORE any handler
/// runs, and the 6003 cases only send CORS pre-flights, so nothing touches the
/// Rekordbox DB or writes to the on-disk data store.
final class SecurityHTTPIntegrationTests: XCTestCase {

    private var server: HTTPServer!
    private var port: UInt16 = 0
    private var base: String { "http://127.0.0.1:\(port)" }

    override func setUpWithError() throws {
        // Try a few high ports so a busy one doesn't fail the suite.
        var lastError: Error?
        for candidate: UInt16 in [19201, 19207, 19213, 19219, 19223] {
            let s = HTTPServer(port: candidate)
            s.router = { APIRouter.shared.route($0) }
            do {
                try s.start()
                server = s
                port = candidate
                lastError = nil
                break
            } catch {
                lastError = error
                s.stop()
            }
        }
        if let lastError { throw lastError }
        // Give the accept loop a moment to come up.
        Thread.sleep(forTimeInterval: 0.15)
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    private func send(_ method: String, _ path: String,
                      headers: [String: String] = [:]) throws -> (Int, [AnyHashable: Any]) {
        let url = URL(string: base + path)!
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sema = DispatchSemaphore(value: 0)
        var status = -1
        var respHeaders: [AnyHashable: Any] = [:]
        var reqError: Error?
        // Ephemeral config so nothing is cached between calls.
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: req) { _, resp, err in
            reqError = err
            if let http = resp as? HTTPURLResponse {
                status = http.statusCode
                respHeaders = http.allHeaderFields
            }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 6)
        if let reqError { throw reqError }
        return (status, respHeaders)
    }

    // 6001: unauthenticated /stream (no PSK, no named tunnel in a test process)
    // must be REJECTED. Before the fix this reached streamAudio and served the file.
    func test_6001_http_unauthenticatedStream_isRejected() throws {
        let (status, _) = try send("GET", "/stream?path=/etc/passwd")
        XCTAssertEqual(status, 401, "unauthenticated /stream must be denied (fail-closed)")
    }

    func test_6001_http_unauthenticatedApiData_isRejected() throws {
        let (status, _) = try send("GET", "/api/data")
        XCTAssertEqual(status, 401)
    }

    // 6003: a CORS pre-flight from an arbitrary origin must NOT get ACAO: * (or any
    // ACAO). Before the fix every response carried Access-Control-Allow-Origin: *.
    func test_6003_http_preflight_arbitraryOrigin_hasNoWildcard() throws {
        let (_, headers) = try send("OPTIONS", "/api/data",
                                    headers: ["Origin": "https://evil.example",
                                              "Access-Control-Request-Method": "GET"])
        let acao = headers["Access-Control-Allow-Origin"] as? String
        XCTAssertNotEqual(acao, "*")
        XCTAssertNil(acao, "no CORS grant for a non-allow-listed origin")
    }

    func test_6003_http_preflight_rimeoOrigin_isReflected() throws {
        let (_, headers) = try send("OPTIONS", "/api/data",
                                    headers: ["Origin": "https://rimeo.app",
                                              "Access-Control-Request-Method": "GET"])
        let acao = headers["Access-Control-Allow-Origin"] as? String
        XCTAssertEqual(acao, "https://rimeo.app")
    }
}
