import AppKit

// Entry point — sets up NSApplication and runs the event loop
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
let startupPolicy: NSApplication.ActivationPolicy = AgentSettings.shared.showInDockEnabled ? .regular : .accessory
NSApplication.shared.setActivationPolicy(startupPolicy)
NSApplication.shared.run()
