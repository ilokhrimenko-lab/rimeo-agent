import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var mainWindow: NSWindow?
    private var updateTimer: Timer?
    private var statusItem: NSStatusItem?
    private let defaultWindowSize = NSSize(width: 1180, height: 820)
    private let minimumWindowSize = NSSize(width: 955, height: 760)
    private var servicesStarted = false
    private var fdaWasGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE (prevents crashes on broken socket writes)
        signal(SIGPIPE, SIG_IGN)

        // Первой строкой — метка старта с данными о ПРЕДЫДУЩЕМ запуске. Лог теперь
        // append-only, поэтому она не затирает историю: по ней видно, сколько раз и
        // как агент перезапускался (exit=unclean ⇒ упал/убит, а не закрыт штатно).
        // 13.07.2026 агент перезапустился 5 раз за 16 минут — и доказать это по логам
        // было нечем, потому что лог стирался при каждом старте.
        logger.boot()

        // Silent auto-update: install a build that was staged (downloaded) in the
        // background during the previous session BEFORE any UI/server comes up, then
        // relaunch into it. applyZip() calls exit(0) on success, so launch stops here.
        if UpdateChecker.shared.applyStagedUpdateIfPresent() { return }

        // Apply the saved appearance BEFORE any window is created so the first
        // frame renders in the correct theme (no dark flash on a light Mac).
        ThemeManager.shared.apply()

        setupAppMenu()
        setupMenuBar()
        // Тихий старт: агента поднял launchd при логине (или он перезапустился после
        // фонового автообновления) — окна нет, только иконка в menu bar. Окно создастся
        // лениво в showWindow(), когда пользователь сам его откроет.
        if AgentSettings.shared.isBackgroundSession {
            logger.info("Boot: background launch — main window suppressed (menu bar only)")
        } else {
            createMainWindow()
        }
        TCCDiagnostics.logIdentityOnce()
        AgentSettings.shared.applyAllAtLaunch()
        AgentSettings.shared.reconcileLaunchAtLoginAtLaunch()
        CacheManager.shared.scheduleEnforce()
        SimilarityEngine.shared.startCloudSync()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(componentGateCleared),
            name: .componentGateCleared,
            object: nil
        )
        checkComponentsAtLaunch()
    }


    /// Штатный выход. Без этой отметки следующий [BOOT] напишет exit=unclean —
    /// именно так в логе отличается падение/kill от нормального закрытия.
    func applicationWillTerminate(_ notification: Notification) {
        logger.markCleanExit()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.refreshDiskAccessBannerState()
        triggerVolumePreAuthIfFDAJustGranted()
    }

    private func triggerVolumePreAuthIfFDAJustGranted() {
        let hasAccess = AppState.hasFullDiskAccess()
        guard hasAccess, !fdaWasGranted else {
            if hasAccess { fdaWasGranted = true }
            return
        }
        fdaWasGranted = true
        logger.info("FDA just detected — running volume pre-authorization")
        DispatchQueue.global(qos: .userInitiated).async {
            preauthorizeRemovableVolumes()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppState.shared.refreshDiskAccessBannerState()
        showWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Window

    private func setupAppMenu() {
        let appName = "Rimeo Agent"
        let mainMenu = NSMenu()

        // ── App menu ──────────────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // ── File menu ─────────────────────────────────────────────────────────
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let openAudio = fileMenu.addItem(withTitle: "Open Audio File…",
                                         action: #selector(openAudioFile),
                                         keyEquivalent: "o")
        openAudio.target = self
        fileMenuItem.submenu = fileMenu

        // ── Edit menu ─────────────────────────────────────────────────────────
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",       action: #selector(UndoManager.undo),        keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",       action: #selector(UndoManager.redo),        keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",        action: #selector(NSText.cut(_:)),           keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",       action: #selector(NSText.copy(_:)),          keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",      action: #selector(NSText.paste(_:)),         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),     keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // ── Window menu ───────────────────────────────────────────────────────
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func createMainWindow() {
        let appState    = AppState.shared
        let contentView = ContentView().environmentObject(appState)
        let controller  = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect:  NSRect(x: 0, y: 0, width: defaultWindowSize.width, height: defaultWindowSize.height),
            styleMask:    [.titled, .closable, .miniaturizable, .resizable],
            backing:      .buffered,
            defer:        false
        )
        window.title              = "Rimeo Agent"
        window.contentViewController = controller
        window.delegate           = self
        window.minSize            = minimumWindowSize
        window.contentMinSize     = minimumWindowSize
        window.center()

        // Hide title bar — modern macOS style
        window.titlebarAppearsTransparent = true
        window.titleVisibility            = .hidden
        window.styleMask.insert(.fullSizeContentView)
        if #available(macOS 13, *) {
            window.titlebarSeparatorStyle = .none
        }

        enforceWindowSize(window, forceDefaultSize: true)
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    func showWindow() {
        // Пользователь сам открыл окно — фоновая сессия закончилась, Dock-иконка
        // возвращается (если она включена в настройках).
        AgentSettings.shared.endBackgroundSession()
        if let w = mainWindow {
            enforceWindowSize(w, forceDefaultSize: false)
            w.makeKeyAndOrderFront(nil)
        } else {
            createMainWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Hard floor on the main window size. `window.minSize`/`contentMinSize` don't
    // reliably hold with an NSHostingController content view (the window can still be
    // dragged down to an unusable sliver), so clamp every resize here.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width:  max(frameSize.width,  minimumWindowSize.width),
               height: max(frameSize.height, minimumWindowSize.height))
    }

    // Close → hide (do not quit)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard case .clear = AppState.shared.componentGateState else {
            return false
        }
        sender.orderOut(nil)
        return false
    }

    private func enforceWindowSize(_ window: NSWindow, forceDefaultSize: Bool) {
        var frame = window.frame
        let needsResize =
            forceDefaultSize ||
            frame.size.width < minimumWindowSize.width ||
            frame.size.height < minimumWindowSize.height

        guard needsResize else { return }

        frame.size.width = max(defaultWindowSize.width, minimumWindowSize.width)
        frame.size.height = max(defaultWindowSize.height, minimumWindowSize.height)
        window.setFrame(frame, display: true, animate: false)
        window.center()
    }

    // MARK: - Status bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.image = Self.makeStatusBarIcon() ?? { button.title = "R"; return nil }()
        button.toolTip = "Rimeo Agent"

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Rimeo Agent",
                                   action: #selector(openFromMenu),
                                   keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit",
                                   action: #selector(quitApp),
                                   keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openFromMenu() { showWindow() }
    @objc private func quitApp()      { NSApp.terminate(nil) }

    // MARK: - Open audio files (Finder "Open With", drag-onto-Dock, File menu)

    // Modern multi-file entry point: Finder "Open With → Rimeo Agent", drag files
    // onto the Dock icon, `open -a`. We analyse the first file; the Check quality
    // window reuses across opens. The hop onto the main actor keeps the
    // @MainActor window manager happy under the Swift 6 compiler.
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("Open file event: \(urls.map { $0.lastPathComponent }.joined(separator: ", "))")
        guard let url = urls.first else { return }
        Task { @MainActor in QualityWindowManager.shared.open(url: url) }
    }

    @objc private func openAudioFile() {
        Task { @MainActor in QualityWindowManager.shared.presentOpenPanel() }
    }

    // Rimeo logo for the status bar. Prefer the real bundled asset (rimeo1024.png);
    // fall back to the drawn badge only for bare swift-build runs without a bundle.
    private static func makeStatusBarIcon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        if let path = Bundle.main.path(forResource: "rimeo1024", ofType: "png"),
           let logo = NSImage(contentsOfFile: path) {
            let icon = NSImage(size: size)
            icon.lockFocus()
            logo.draw(in: NSRect(origin: .zero, size: size),
                      from: .zero, operation: .sourceOver, fraction: 1.0)
            icon.unlockFocus()
            icon.isTemplate = false   // keep the brand blue, not a monochrome template
            return icon
        }
        let image = NSImage(size: size, flipped: false) { rect in
            // Blue background matching the logo (#0019C8)
            NSColor(red: 0/255, green: 25/255, blue: 200/255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

            // White "R" — heavy weight, centered
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
                .foregroundColor: NSColor.white,
            ]
            let letter = "R" as NSString
            let letterSize = letter.size(withAttributes: attrs)
            let origin = NSPoint(
                x: (rect.width  - letterSize.width)  / 2,
                y: (rect.height - letterSize.height) / 2
            )
            letter.draw(at: origin, withAttributes: attrs)
            return true
        }
        return image
    }

    // MARK: - Services startup

    @objc private func componentGateCleared() {
        startServices()
    }

    private func checkComponentsAtLaunch() {
        AppState.shared.componentGateState = .checking
        Task {
            do {
                let missing = try await ComponentManager.shared.checkMissing()
                await MainActor.run {
                    if missing.isEmpty {
                        AppState.shared.componentGateState = .clear
                        self.startServices()
                    } else {
                        AppState.shared.componentGateState = .required(missing)
                        self.forceShowWindowIfBackground(
                            "missing components: \(missing.map { $0.id }.joined(separator: ", "))")
                    }
                }
            } catch {
                await MainActor.run {
                    AppState.shared.componentGateState = .error(error.localizedDescription)
                    self.forceShowWindowIfBackground("component check failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // Компонентный гейт не пройден ⇒ startServices() не вызывается и агент фактически
    // мёртв: ни HTTP-сервера, ни туннеля. Чинится это только руками в UI, поэтому при
    // фоновом старте окно всё-таки показываем — иначе пользователь молча остаётся без
    // работающего агента и без единого намёка почему.
    private func forceShowWindowIfBackground(_ reason: String) {
        guard AgentSettings.shared.isBackgroundSession else { return }
        logger.warning("Background launch blocked (\(reason)) — showing the window")
        showWindow()
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true

        // HTTP server
        let server = HTTPServer(port: AppConfig.shared.port)
        server.router = { APIRouter.shared.route($0) }
        do {
            try server.start()
            // M4: advertise on the LAN so the iOS app can discover us over Bonjour.
            BonjourAdvertiser.shared.start(port: AppConfig.shared.port,
                                           agentID: AppConfig.shared.agentID)
        } catch {
            logger.error("HTTP server failed to start: \(error)")
        }

        // Pre-authorize removable volumes at startup so TCC consent is established
        // before any streaming request arrives.
        DispatchQueue.global(qos: .userInitiated).async {
            preauthorizeRemovableVolumes()
        }

        // Log cloudflared availability immediately (visible in first lines of log)
        let cfPath = TunnelManager.shared.findCloudflared()
        logger.info("Startup: cloudflared_found=\(cfPath != nil), path=\(cfPath ?? "none")")

        // Auto-start tunnel if cloudflared available
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            TunnelManager.shared.autoStartIfAvailable()
        }

        // Start cloud relay if already linked
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            CloudRelay.shared.startIfLinked()
        }

        // П8: ask the server for a per-user named tunnel and migrate off the
        // shared quick tunnel. No-op when already named / not linked / rollout
        // gate declines.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            TunnelProvisioner.shared.provisionIfNeeded()
        }

        // Silent auto-update: check shortly after launch and every hour, downloading
        // any newer build to a staging file in the background. It installs itself on
        // the NEXT launch (applyStagedUpdateIfPresent at the top of this method) —
        // no banner, no prompt.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) {
            UpdateChecker.shared.checkAndStageSilently()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            UpdateChecker.shared.checkAndStageSilently()
        }
    }

    func triggerUpdate(_ info: UpdateInfo) {
        downloadUpdate(info)
    }

    private func showUpdateBanner(_ info: UpdateInfo) {
        guard let window = mainWindow else { return }
        let alert = NSAlert()
        alert.messageText     = "Update Available: \(info.version)"
        alert.informativeText = info.notes.isEmpty ? "A new version is available." : info.notes
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { [weak self] resp in
            if resp == .alertFirstButtonReturn {
                self?.downloadUpdate(info)
            }
        }
    }

    private func downloadUpdate(_ info: UpdateInfo) {
        guard let window = mainWindow else { return }

        let sheetRect = NSRect(x: 0, y: 0, width: 380, height: 80)
        let sheet = NSPanel(contentRect: sheetRect, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Downloading Update"

        let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 36, width: 332, height: 20))
        bar.style = .bar; bar.minValue = 0; bar.maxValue = 100
        bar.doubleValue = 0; bar.isIndeterminate = false

        let lbl = NSTextField(labelWithString: "Downloading \(info.version)…")
        lbl.frame = NSRect(x: 24, y: 12, width: 332, height: 18)
        lbl.font = .systemFont(ofSize: 12)
        lbl.textColor = .secondaryLabelColor

        let cv = NSView(frame: sheetRect)
        cv.addSubview(bar); cv.addSubview(lbl)
        sheet.contentView = cv

        window.beginSheet(sheet) { _ in }

        DispatchQueue.global(qos: .utility).async {
            do {
                try UpdateChecker.shared.downloadAndApply(info) { pct in
                    DispatchQueue.main.async { bar.doubleValue = pct * 100 }
                }
                // App exits via exit(0) in downloadAndApply — sheet closes with the process
            } catch {
                DispatchQueue.main.async {
                    window.endSheet(sheet)
                    let alert = NSAlert()
                    alert.messageText     = "Update Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - Removable volume pre-authorization

// Probes each unique /Volumes/<name> mount found in the Rekordbox library so that
// TCC consent is established at startup rather than during playback/streaming.
// Uses the volume root directory — more reliable than a specific file which may have moved.
// Falls back to a known track file if the directory listing fails.
private func preauthorizeRemovableVolumes() {
    // Skip pre-auth only if FDA is reliably detected as not granted.
    // With ad-hoc signing, hasFullDiskAccess() is unreliable — always run pre-auth
    // so kTCCServiceRemovableVolumes consent is established at startup.
    let fdaOk = AppState.hasFullDiskAccess()
    let fdaReliable = TCCDiagnostics.isReliablyDetectable()
    guard fdaOk || !fdaReliable else {
        logger.info("Volume pre-auth skipped: Full Disk Access not yet granted")
        return
    }

    let lib = RekordboxParser.shared.parse()
    guard !lib.tracks.isEmpty else {
        logger.info("Volume pre-auth skipped: library is empty")
        return
    }

    // Collect up to 5 track paths per /Volumes/<name> mount point as fallbacks.
    var volumeRoots: [String: [String]] = [:]  // volumeName → [trackPath]
    for track in lib.tracks {
        let path = track.location
        guard path.hasPrefix("/Volumes/") else { continue }
        let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { continue }
        let name = String(parts[2])
        if (volumeRoots[name]?.count ?? 0) < 5 {
            volumeRoots[name, default: []].append(path)
        }
    }

    guard !volumeRoots.isEmpty else {
        logger.info("Volume pre-auth: no /Volumes tracks in library")
        return
    }

    logger.info("Volume pre-auth: probing \(volumeRoots.count) volume(s): \(volumeRoots.keys.sorted().joined(separator: ", "))")

    let fm = FileManager.default
    for (name, trackPaths) in volumeRoots {
        let root = "/Volumes/\(name)"
        var authorized = false

        // Open an actual file — this is what establishes kTCCServiceRemovableVolumes consent.
        // Directory listing does NOT trigger the consent check for file reads.
        for trackPath in trackPaths {
            if let fh = FileHandle(forReadingAtPath: trackPath) {
                fh.closeFile()  // open() call is the TCC trigger — reading is not required
                logger.info("Volume pre-auth OK: \(name) via \(trackPath)")
                authorized = true
                break
            }
        }

        if !authorized {
            let mounted = (try? fm.contentsOfDirectory(atPath: root)) != nil
            if mounted {
                logger.warning("Volume pre-auth: dir OK but no readable track for \(name) — possible TCC dialog on first play")
            } else {
                logger.warning("Volume pre-auth failed for \(name) — volume may not be mounted")
            }
        }
    }
}
