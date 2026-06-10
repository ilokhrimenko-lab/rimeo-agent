import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let defaultWindowSize = NSSize(width: 1180, height: 820)
    private let minimumWindowSize = NSSize(width: 1120, height: 760)
    private var servicesStarted = false
    private var fdaWasGranted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE (prevents crashes on broken socket writes)
        signal(SIGPIPE, SIG_IGN)

        setupAppMenu()
        setupMenuBar()
        createMainWindow()
        TCCDiagnostics.logIdentityOnce()
        AgentSettings.shared.applyAllAtLaunch()
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
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit Rimeo Agent",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu

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
        if let w = mainWindow {
            enforceWindowSize(w, forceDefaultSize: false)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            createMainWindow()
        }
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

    // Draw the Rimeo logo (blue square + white R) at 18×18 for the status bar.
    private static func makeStatusBarIcon() -> NSImage? {
        let size = NSSize(width: 18, height: 18)
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
                    }
                }
            } catch {
                await MainActor.run {
                    AppState.shared.componentGateState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true

        // HTTP server
        let server = HTTPServer(port: AppConfig.shared.port)
        server.router = { APIRouter.shared.route($0) }
        do {
            try server.start()
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

        // Apply pending update (scheduled via "Update on Next Launch")
        if let pending = UpdateChecker.shared.pendingUpdate {
            UpdateChecker.shared.clearPending()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.downloadUpdate(pending)
            }
        } else {
            // Routine background update check (once per 24h)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                UpdateChecker.shared.checkAsync { info in
                    guard let info else { return }
                    DispatchQueue.main.async { self.showUpdateBanner(info) }
                }
            }
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
