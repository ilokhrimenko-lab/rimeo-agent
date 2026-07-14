import Foundation
import AppKit
import ServiceManagement

final class AgentSettings {
    static let shared = AgentSettings()

    /// Имя plist LaunchAgent'а внутри бандла (Contents/Library/LaunchAgents/).
    /// Совпадает с его Label — SMAppService ищет job по имени файла.
    static let launchAgentPlistName = "app.rimeo.agent.autostart.plist"

    /// Переменная окружения из этого plist: «процесс поднял launchd при логине».
    static let backgroundEnvKey = "RIMEO_BACKGROUND"

    /// То же самое, но аргументом: при перезапуске после автообновления агент
    /// стартуется через `/usr/bin/open <app> --args --background`, туда окружение
    /// не пробросить.
    static let backgroundLaunchArgument = "--background"

    /// Нас поднял launchd. Читается из окружения процесса, поэтому валидно на любой
    /// стадии старта — в т.ч. до applicationDidFinishLaunching.
    static let isLaunchdLaunch: Bool =
        ProcessInfo.processInfo.environment[AgentSettings.backgroundEnvKey] == "1"

    /// Тихий фоновый старт: launchd при логине ИЛИ перезапуск после апдейта агента,
    /// который и до апдейта работал в фоне.
    static let isBackgroundLaunch: Bool =
        AgentSettings.isLaunchdLaunch
        || ProcessInfo.processInfo.arguments.contains(AgentSettings.backgroundLaunchArgument)

    private enum Key {
        static let launchAtLogin = "rimeo_settings_launch_at_login"
        static let showInDock = "rimeo_settings_show_in_dock"
        static let keepAlive247 = "rimeo_settings_keep_alive_247"
        // Автозапуск включаем сами РОВНО ОДИН раз. Без этого флага пользователь не смог бы
        // его выключить: выключил — а мы на следующем старте включили обратно.
        static let autostartOffered = "rimeo_settings_autostart_offered"
        // Старые сборки регистрировали login item как SMAppService.mainApp. Снимаем его
        // один раз, иначе после перехода на LaunchAgent агент будет стартовать дважды.
        static let launchAgentMigrated = "rimeo_settings_launch_agent_migrated"
    }

    private let defaults = UserDefaults.standard
    private var keepAliveProcess: Process?

    /// Пока true — окно не показываем и иконку в Dock не поднимаем. Сбрасывается, как
    /// только пользователь сам открывает окно (menu bar / Finder / Dock).
    private(set) var isBackgroundSession: Bool = AgentSettings.isBackgroundLaunch

    private init() {}

    var launchAtLoginEnabled: Bool {
        defaults.bool(forKey: Key.launchAtLogin)
    }

    func endBackgroundSession() {
        guard isBackgroundSession else { return }
        isBackgroundSession = false
        applyDockVisibility()
    }

    var showInDockEnabled: Bool {
        if defaults.object(forKey: Key.showInDock) == nil { return true }
        return defaults.bool(forKey: Key.showInDock)
    }

    var keepAlive247Enabled: Bool {
        defaults.bool(forKey: Key.keepAlive247)
    }

    @available(macOS 13.0, *)
    private var launchAgentService: SMAppService {
        SMAppService.agent(plistName: Self.launchAgentPlistName)
    }

    /// Реальный статус автозапуска у launchd. Сначала смотрим на LaunchAgent, и только
    /// если его нет — на старую регистрацию самого .app (не мигрировавший пользователь
    /// или fallback-режим, когда plist в бандле отсутствует).
    @available(macOS 13.0, *)
    var launchAtLoginStatus: SMAppService.Status {
        let agent = launchAgentService.status
        if agent == .enabled || agent == .requiresApproval { return agent }
        return SMAppService.mainApp.status
    }

    /// ПРАВДА для тумблера: спрашиваем launchd, а не UserDefaults. Регистрация могла
    /// отвалиться (переустановка бандла) или быть снята пользователем в System Settings.
    var launchAtLoginActive: Bool {
        if #available(macOS 13.0, *) {
            switch launchAtLoginStatus {
            case .enabled, .requiresApproval: return true
            default: return false
            }
        }
        return launchAtLoginEnabled
    }

    /// Регистрация есть, но macOS ждёт подтверждения в System Settings → Login Items.
    var launchAtLoginNeedsApproval: Bool {
        if #available(macOS 13.0, *) {
            return launchAtLoginStatus == .requiresApproval
        }
        return false
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(
                domain: "RimeoAgent.Settings",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launch at login requires macOS 13 or newer."]
            )
        }

        if enabled {
            do {
                try launchAgentService.register()
                // Старый login item мог остаться от предыдущих версий — снимаем, иначе
                // при логине агент поднимется ДВАЖДЫ.
                try? SMAppService.mainApp.unregister()
            } catch {
                // Бандла с plist нет (dev-сборка `swift build`, ручная распаковка) —
                // откатываемся на регистрацию самого .app, иначе автозапуска не будет вовсе.
                // Минус fallback'а: окно при логине покажется, как в старых версиях.
                logger.warning("Settings: LaunchAgent register failed (\(error.localizedDescription)) — falling back to app login item")
                try SMAppService.mainApp.register()
            }
        } else {
            // Снимаем ОБА варианта: у мигрирующего пользователя в системе может лежать
            // и старая регистрация .app, и новый LaunchAgent.
            try? launchAgentService.unregister()
            try? SMAppService.mainApp.unregister()
        }
        defaults.set(enabled, forKey: Key.launchAtLogin)
    }

    /// Вызывается один раз при старте:
    /// 1) снимает старую регистрацию .app как login item (миграция на LaunchAgent);
    /// 2) РОВНО ОДИН раз включает автозапуск по умолчанию (дальше — воля пользователя);
    /// 3) чинит рассинхрон «в настройках включено, а в launchd job'а нет».
    func reconcileLaunchAtLoginAtLaunch() {
        guard #available(macOS 13.0, *) else { return }

        var justMigrated = false
        if !defaults.bool(forKey: Key.launchAgentMigrated) {
            defaults.set(true, forKey: Key.launchAgentMigrated)
            justMigrated = true
            if SMAppService.mainApp.status == .enabled {
                do {
                    try SMAppService.mainApp.unregister()
                    logger.info("Settings: legacy app login item unregistered (migrating to LaunchAgent)")
                } catch {
                    logger.warning("Settings: failed to unregister legacy login item: \(error.localizedDescription)")
                }
            }
        }

        // Пользователь уже осознанно трогал тумблер в прошлых версиях — не навязываем.
        if defaults.object(forKey: Key.launchAtLogin) != nil {
            defaults.set(true, forKey: Key.autostartOffered)
        }

        if !defaults.bool(forKey: Key.autostartOffered) {
            defaults.set(true, forKey: Key.autostartOffered)
            do {
                try setLaunchAtLogin(true)
                logger.info("Settings: launch at login enabled by default (first run)")
            } catch {
                logger.warning("Settings: default launch-at-login registration failed: \(error.localizedDescription)")
            }
            return
        }

        // Автозапуск включён, но job'а в launchd нет (мигрировали с mainApp, переустановили
        // бандл). requiresApproval НЕ трогаем — это осознанный запрет в System Settings.
        guard launchAtLoginEnabled else { return }
        let status = launchAtLoginStatus
        guard justMigrated || status == .notRegistered || status == .notFound else { return }
        do {
            try setLaunchAtLogin(true)
            logger.info("Settings: launch at login re-registered (launchd status was \(status.rawValue))")
        } catch {
            logger.warning("Settings: launch-at-login re-registration failed: \(error.localizedDescription)")
        }
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
        // В фоновой сессии Dock-иконки нет независимо от настройки: агент подняли при
        // логине, окна нет, светиться в Dock нечем. Как только пользователь откроет окно
        // (endBackgroundSession), настройка вступит в силу.
        let visible = showInDockEnabled && !isBackgroundSession
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
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
        p.arguments = ["-i"]
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
