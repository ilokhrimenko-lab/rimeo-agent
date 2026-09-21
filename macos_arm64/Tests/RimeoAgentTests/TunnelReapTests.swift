import XCTest
@testable import RimeoAgent

/// Добивание осиротевшего tunnel-runtime перед запуском своего (TunnelManager.terminateAndWait).
/// Раньше SIGTERM слался без ожидания: пока сирота закрывала соединения, на туннеле висели два
/// коннектора и стрим заикался.
final class TunnelReapTests: XCTestCase {

    private func spawn(_ script: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        Thread.sleep(forTimeInterval: 0.2)   // дать shell поставить trap
        return p
    }

    func test_exitsOnSigterm_noSigkill() throws {
        let p = try spawn("exec /bin/sleep 30")
        let t0 = Date()
        let killed = TunnelManager.terminateAndWait([p.processIdentifier], grace: 3)
        p.waitUntilExit()
        XCTAssertEqual(killed, [], "процесс, который уходит по SIGTERM, не должен получать SIGKILL")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
    }

    func test_ignoresSigterm_getsSigkillAfterGrace() throws {
        let p = try spawn("trap '' TERM; while :; do /bin/sleep 0.1; done")
        let t0 = Date()
        let killed = TunnelManager.terminateAndWait([p.processIdentifier], grace: 1)
        p.waitUntilExit()
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(killed, [p.processIdentifier])
        XCTAssertGreaterThanOrEqual(elapsed, 0.9, "до SIGKILL должен быть дан grace")
        XCTAssertLessThan(elapsed, 3)
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
    }

    func test_emptyList_isNoop() {
        XCTAssertEqual(TunnelManager.terminateAndWait([], grace: 3), [])
    }
}
