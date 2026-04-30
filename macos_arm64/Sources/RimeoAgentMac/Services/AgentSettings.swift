import Foundation
import AppKit
import ServiceManagement

final class AgentSettings {
    static let shared = AgentSettings()

    private enum Key {
        static let launchAtLogin = "rimeo_settings_launch_at_login"
        static let showInDock = "rimeo_settings_show_in_dock"
        static let keepAlive247 = "rimeo_settings_keep_alive_247"
    }

    private let defaults = UserDefaults.standard
    private var keepAliveProcess: Process?

    private init() {}

    var launchAtLoginEnabled: Bool {
        defaults.bool(forKey: Key.launchAtLogin)
    }

    var showInDockEnabled: Bool {
        if defaults.object(forKey: Key.showInDock) == nil { return true }
        return defaults.bool(forKey: Key.showInDock)
    }

    var keepAlive247Enabled: Bool {
        defaults.bool(forKey: Key.keepAlive247)
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } else {
            throw NSError(
                domain: "RimeoAgent.Settings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launch at login requires macOS 13 or newer."]
            )
        }
        defaults.set(enabled, forKey: Key.launchAtLogin)
    }

    func setShowInDock(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.showInDock)
        applyDockVisibility()
    }

    func setKeepAlive247(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.keepAlive247)
        applyKeepAlivePreference()
    }

    func applyAllAtLaunch() {
        applyDockVisibility()
        applyKeepAlivePreference()
    }

    func applyDockVisibility() {
        let policy: NSApplication.ActivationPolicy = showInDockEnabled ? .regular : .accessory
        _ = NSApplication.shared.setActivationPolicy(policy)
    }

    func applyKeepAlivePreference() {
        if keepAlive247Enabled {
            startKeepAliveAssertion()
        } else {
            stopKeepAliveAssertion()
        }
    }

    private func startKeepAliveAssertion() {
        if keepAliveProcess?.isRunning == true { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-dimsu"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
            keepAliveProcess = p
            logger.info("Settings: keep-alive assertion enabled via caffeinate")
        } catch {
            keepAliveProcess = nil
            logger.error("Settings: failed to start caffeinate: \(error.localizedDescription)")
        }
    }

    private func stopKeepAliveAssertion() {
        guard let p = keepAliveProcess else { return }
        if p.isRunning { p.terminate() }
        keepAliveProcess = nil
        logger.info("Settings: keep-alive assertion disabled")
    }
}
