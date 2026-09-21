import XCTest
@testable import RimeoAgent

/// Перезапуск после обновления (UpdateChecker.relaunchCommand). Раньше было
/// `open <app>` + сразу `exit(0)`, и агент после обновления из iOS мог не подняться:
/// `open` без `-n` не создавал второй экземпляр, пока старый ещё жив, а унаследованный
/// RIMEO_BACKGROUND=1 заставлял новый процесс молча выйти на гарде в main.swift.
final class UpdateRelaunchTests: XCTestCase {

    private let app = "/Applications/Rimeo Agent's.app"

    func test_background_passesFlagAsArgument_forcesNewInstance_keepsFocus() {
        let cmd = UpdateChecker.relaunchCommand(pid: 4242, appPath: app, background: true,
                                                environment: [:])
        XCTAssertEqual(cmd.arguments[0], "-c")
        XCTAssertEqual(cmd.arguments[2], "4242", "$0 скрипта — PID, которого ждём")
        XCTAssertEqual(Array(cmd.arguments.dropFirst(3)),
                       ["-n", "-g", app, "--args", AgentSettings.backgroundLaunchArgument,
                        UpdateChecker.relaunchedFromArgument, "4242"])
    }

    func test_foreground_noBackgroundFlag_stillNoFocusSteal() {
        let cmd = UpdateChecker.relaunchCommand(pid: 1, appPath: app, background: false,
                                                environment: [:])
        XCTAssertEqual(Array(cmd.arguments.dropFirst(3)),
                       ["-n", "-g", app, "--args", UpdateChecker.relaunchedFromArgument, "1"],
                       "-g всегда: перезапуск не отнимает фокус и в обычном режиме")
    }

    func test_relaunchedFromPID_parsing() {
        XCTAssertEqual(UpdateChecker.relaunchedFromPID(
            arguments: ["/x/RimeoAgent", "--background", "--relaunched-from", "4242"]), 4242)
        XCTAssertNil(UpdateChecker.relaunchedFromPID(arguments: ["/x/RimeoAgent", "--background"]))
        XCTAssertNil(UpdateChecker.relaunchedFromPID(arguments: ["/x/RimeoAgent", "--relaunched-from"]))
        XCTAssertNil(UpdateChecker.relaunchedFromPID(arguments: ["/x/RimeoAgent", "--relaunched-from", "abc"]))
        XCTAssertNil(UpdateChecker.relaunchedFromPID(arguments: ["/x/RimeoAgent", "--relaunched-from", "0"]))
    }

    func test_launchdEnvironment_isStripped_restKept() {
        let cmd = UpdateChecker.relaunchCommand(
            pid: 1, appPath: app, background: true,
            environment: [AgentSettings.backgroundEnvKey: "1",
                          "XPC_SERVICE_NAME": "app.rimeo.agent.autostart",
                          "HOME": "/Users/x"])
        XCTAssertNil(cmd.environment[AgentSettings.backgroundEnvKey],
                     "с RIMEO_BACKGROUND=1 новый процесс сочтёт себя launchd-стартом и выйдет")
        XCTAssertNil(cmd.environment["XPC_SERVICE_NAME"])
        XCTAssertEqual(cmd.environment["HOME"], "/Users/x")
    }

    func test_appPath_isNeverInterpolatedIntoScript() {
        let cmd = UpdateChecker.relaunchCommand(pid: 1, appPath: "/tmp/x'; rm -rf ~; '.app",
                                                background: false, environment: [:])
        XCTAssertFalse(cmd.arguments[1].contains("rm -rf"), "путь — аргумент, не часть скрипта")
    }

    /// Живой прогон скрипта: вместо /usr/bin/open подставлен /bin/echo, вместо агента —
    /// короткоживущий sleep. Скрипт обязан дождаться его смерти и только потом «открыть».
    func test_script_waitsForOldProcess_thenRunsOpen() throws {
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/bin/sleep")
        old.arguments = ["0.6"]
        try old.run()

        let cmd = UpdateChecker.relaunchCommand(pid: old.processIdentifier, appPath: app,
                                                background: true, environment: [:])
        var args = cmd.arguments
        args[1] = args[1].replacingOccurrences(of: "/usr/bin/open", with: "/bin/echo")

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = args
        let pipe = Pipe()
        sh.standardOutput = pipe
        let t0 = Date()
        try sh.run()
        sh.waitUntilExit()
        let elapsed = Date().timeIntervalSince(t0)
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertGreaterThanOrEqual(elapsed, 0.5, "open не должен запускаться, пока старый процесс жив")
        XCTAssertLessThan(elapsed, 5, "умерший процесс не должен ждаться до таймаута")
        XCTAssertFalse(out.contains("still alive"), out)
        XCTAssertTrue(out.contains("-n -g \(app) --args --background --relaunched-from \(old.processIdentifier)"), out)
        XCTAssertTrue(out.contains("open exit=0"), out)
    }
}

final class RelaunchModeTests: XCTestCase {
    func test_backgroundUnlessWindowOnScreen() {
        XCTAssertTrue(UpdateChecker.relaunchInBackground(isBackgroundSession: true, windowShown: false))
        XCTAssertTrue(UpdateChecker.relaunchInBackground(isBackgroundSession: true, windowShown: true))
        XCTAssertTrue(UpdateChecker.relaunchInBackground(isBackgroundSession: false, windowShown: false),
                      "окно открывали и закрыли — после обновления не всплывать")
        XCTAssertFalse(UpdateChecker.relaunchInBackground(isBackgroundSession: false, windowShown: true),
                       "окно на экране — вернуть его")
    }
    func test_onScreenWindow_falseForWindowlessProcess() {
        // xctest окон не рисует — у текущего процесса окна на экране нет.
        XCTAssertFalse(UpdateChecker.hasOnScreenWindow(pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(UpdateChecker.hasOnScreenWindow(pid: 999_999))
    }

    func test_windowFlag_roundTrip() {
        let s = AgentSettings.shared
        let before = s.mainWindowShown
        s.setMainWindowShown(true);  XCTAssertTrue(s.mainWindowShown)
        s.setMainWindowShown(false); XCTAssertFalse(s.mainWindowShown)
        s.setMainWindowShown(before)
    }
}
