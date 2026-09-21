import XCTest
@testable import RimeoAgent

/// Режим «не спать 24/7» (caffeinate). Раньше `caffeinate -i` без `-w` переживал агента
/// после каждого exit(0) при обновлении и навсегда не давал маку спать.
final class KeepAliveTests: XCTestCase {

    func test_arguments_bindAssertionToAgentPid() {
        XCTAssertEqual(AgentSettings.keepAliveArguments(pid: 4242), ["-i", "-w", "4242"])
    }

    /// Живой прогон: caffeinate с `-w` на короткоживущий процесс обязан завершиться сам,
    /// как только этот процесс умер.
    func test_caffeinate_exitsWhenWatchedProcessDies() throws {
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["0.5"]
        try owner.run()

        let caf = Process()
        caf.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caf.arguments = AgentSettings.keepAliveArguments(pid: owner.processIdentifier)
        try caf.run()

        let deadline = Date().addingTimeInterval(5)
        while caf.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let stillRunning = caf.isRunning
        if stillRunning { caf.terminate() }
        XCTAssertFalse(stillRunning, "caffeinate должен завершиться вместе с отслеживаемым процессом")
    }
}
