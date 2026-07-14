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

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
// Политика Dock учитывает фоновый старт: поднятый launchd'ом агент в Dock не светится,
// даже если "Show in Dock" включён в настройках.
AgentSettings.shared.applyDockVisibility()
NSApplication.shared.run()
