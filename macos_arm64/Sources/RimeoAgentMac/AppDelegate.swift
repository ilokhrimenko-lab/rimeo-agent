import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let defaultWindowSize = NSSize(width: 1180, height: 820)
    private let minimumWindowSize = NSSize(width: 1120, height: 760)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE (prevents crashes on broken socket writes)
        signal(SIGPIPE, SIG_IGN)

        setupAppMenu()
        setupMenuBar()
        createMainWindow()
        startServices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
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
        button.image = NSImage(named: NSImage.Name("NSApplicationIcon"))
            .map { img -> NSImage in
                let copy = img.copy() as! NSImage
                copy.size = NSSize(width: 18, height: 18)
                copy.isTemplate = true
                return copy
            }
        if button.image == nil {
            button.title = "R"
        }
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

    // MARK: - Services startup

    private func startServices() {
        // HTTP server
        let server = HTTPServer(port: AppConfig.shared.port)
        server.router = { APIRouter.shared.route($0) }
        do {
            try server.start()
        } catch {
            logger.error("HTTP server failed to start: \(error)")
        }

        // Auto-start tunnel if cloudflared available
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            TunnelManager.shared.autoStartIfAvailable()
        }

        // Start cloud relay if already linked
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            CloudRelay.shared.startIfLinked()
        }

        // Check for updates after 4s
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            UpdateChecker.shared.checkAsync { info in
                guard let info else { return }
                DispatchQueue.main.async { self.showUpdateBanner(info) }
            }
        }
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
        DispatchQueue.global(qos: .utility).async {
            do {
                try UpdateChecker.shared.downloadAndApply(info) { _ in }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText     = "Update Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}
