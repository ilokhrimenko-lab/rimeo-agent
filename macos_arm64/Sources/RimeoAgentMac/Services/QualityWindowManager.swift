//
//  QualityWindowManager.swift
//  RimeoAgent (macOS)
//
//  Owns a single reusable "Check quality" window and drives it from opened /
//  dropped audio files. Called from AppDelegate's file-open handlers and the
//  "File → Open Audio File…" menu item.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class QualityWindowManager: NSObject, NSWindowDelegate {
    static let shared = QualityWindowManager()

    private var window: NSWindow?
    private let model = QualityModel()

    private let defaultSize = NSSize(width: 468, height: 668)
    private let minSize     = NSSize(width: 468, height: 668)

    /// Analyse `url` and bring the spectrogram window to the front.
    func open(url: URL) {
        logger.info("Quality window open: \(url.lastPathComponent), existingWindow=\(window != nil)")
        guard requireSignedIn() else { return }
        ensureWindow()
        model.load(url: url)
        // A file the user explicitly opened deserves a real foreground window:
        // promote from the menu-bar (.accessory) activation policy so it shows in
        // the Dock / Cmd-Tab, then focus it.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open a file picker limited to audio, then analyse the choice.
    func presentOpenPanel() {
        guard requireSignedIn() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose an audio file to analyze"
        panel.prompt = "Analyze"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    // MARK: - Auth gate

    /// Check quality is an account feature: block it until the agent is signed in.
    /// When signed out, surface the main window's sign-in gate and explain why,
    /// instead of silently analysing the file.
    private func requireSignedIn() -> Bool {
        // Check the persisted account state too: AppState.cloudLinked stays false
        // until refreshFromData() runs at launch, so an Open-With that races startup
        // would otherwise falsely gate an already signed-in user.
        if AppState.shared.cloudLinked || !DataStore.shared.data.cloud_url.isEmpty { return true }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        let delegate = NSApp.delegate as? AppDelegate
        delegate?.showWindow()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Sign in to Rimeo Agent"
        alert.informativeText = "Check quality is available once you sign in to your Rimeo account."
        alert.addButton(withTitle: "OK")
        // Attach as a non-blocking sheet on the main window (which now shows the
        // sign-in gate). `runModal()` would block the main thread and can wedge
        // service startup if the open-file event races app launch.
        if let w = delegate?.mainWindow {
            alert.beginSheetModal(for: w, completionHandler: nil)
        } else {
            alert.runModal()
        }
        return false
    }

    // MARK: - Window lifecycle

    private func ensureWindow() {
        if window != nil { return }

        let root = CheckQualityRootView().environmentObject(model)
        let hosting = NSHostingController(rootView: root)
        // macOS 13+ NSHostingController defaults to sizing the window to the SwiftUI
        // view's fitting size. Our root is a ScrollView whose ideal height ≈ 0, which
        // would collapse the window to a sliver. Opt out so the window keeps its own
        // frame and the ScrollView just fills it.
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Check quality"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false          // we retain it; reuse across opens
        w.isRestorable = false                  // don't let macOS restore a stale user-resized frame over our computed size
        w.contentViewController = hosting
        w.setContentSize(defaultSize)           // enforce our size after attaching the controller
        w.delegate = self
        w.minSize = minSize
        w.contentMinSize = minSize
        w.center()
        window = w
    }

    // Hard floor on the window size. `minSize`/`contentMinSize` alone don't reliably
    // hold with an NSHostingController whose sizing is opted out, so clamp here too —
    // this is what actually stops the window being crushed to an unusable sliver.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width:  max(frameSize.width,  minSize.width),
               height: max(frameSize.height, minSize.height))
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the reference so the next open builds a fresh window, and let the
        // model release its result. The app itself keeps running in the menu bar.
        window = nil
        model.state = .idle
    }
}
