import AppKit

// Entry point — sets up NSApplication and runs the event loop

// SMAppService.register() бутстрапит LaunchAgent с RunAtLoad=true, поэтому launchd
// поднимает вторую копию агента ПРЯМО в момент включения автозапуска, пока первая
// работает. Такая копия молча уходит: порт, Bonjour и туннель уже держит живой процесс.
// Проверка только для launchd-старта — перезапуск после автообновления идёт с
// --background, и там гасить себя нельзя (старый процесс как раз умирает).
private func isAnotherAgentInstanceRunning() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let myPID = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != myPID && !$0.isTerminated }
}

if AgentSettings.isLaunchdLaunch && isAnotherAgentInstanceRunning() {
    exit(0)
}

// Перезапуск после обновления идёт через `open -n` (UpdateChecker.relaunchCommand):
// он поднимает новый экземпляр, даже если агента уже кто-то запустил, пока старый
// умирал. Тогда уходим мы — второй агент поднял бы свой туннель и релей. Старый PID
// исключаем явно, а живость проверяем kill(pid, 0): LaunchServices ещё какое-то
// время числит умерший процесс запущенным, и без этого новый агент выходил бы зря.
private func isAnotherLiveAgentInstance(excluding oldPID: Int32) -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let myPID = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
        let pid = $0.processIdentifier
        return pid != myPID && pid != oldPID && !$0.isTerminated && kill(pid, 0) == 0
    }
}

if let oldPID = UpdateChecker.relaunchedFromPID(arguments: CommandLine.arguments),
   isAnotherLiveAgentInstance(excluding: oldPID) {
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
// Политика Dock учитывает фоновый старт: поднятый launchd'ом агент в Dock не светится,
// даже если "Show in Dock" включён в настройках.
AgentSettings.shared.applyDockVisibility()
NSApplication.shared.run()
