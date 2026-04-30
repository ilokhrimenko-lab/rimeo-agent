import AppKit
import SwiftUI

struct ComponentGateView: View {
    @EnvironmentObject var appState: AppState
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 46, weight: .semibold))
                .foregroundColor(iconColor)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(C.text)

                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(C.dim)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .frame(maxWidth: 480)
            }

            content
                .frame(width: 360)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .background(C.bg)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch appState.componentGateState {
        case .checking:
            ProgressView()
                .controlSize(.large)

        case .required(let components):
            RimeoButton(title: "Install", icon: "arrow.down.circle", color: C.acc) {
                install(components)
            }
            .disabled(isWorking)

        case .downloading(let progress, let label):
            VStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text("\(label) \(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(C.dim)
            }

        case .restartRequired:
            RimeoButton(title: "Restart", icon: "arrow.clockwise", color: C.acc) {
                NSApplication.shared.relaunch()
            }

        case .error:
            RimeoButton(title: "Try Again", icon: "arrow.clockwise", color: C.acc) {
                retryCheck()
            }
            .disabled(isWorking)

        case .clear:
            EmptyView()
        }
    }

    private var iconName: String {
        switch appState.componentGateState {
        case .restartRequired: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        default: return "arrow.down.circle"
        }
    }

    private var iconColor: Color {
        switch appState.componentGateState {
        case .restartRequired: return C.green
        case .error: return C.amber
        default: return C.acc
        }
    }

    private var title: String {
        switch appState.componentGateState {
        case .checking: return "Preparing Rimeo Agent…"
        case .required: return "Update Required"
        case .downloading: return "Installing…"
        case .restartRequired: return "Ready"
        case .error: return "Update Failed"
        case .clear: return ""
        }
    }

    private var message: String {
        switch appState.componentGateState {
        case .checking:
            return "Checking required system components before startup."
        case .required:
            return "Rimeo Agent needs to install required modules before it can continue. This should only take a moment."
        case .downloading:
            return "Downloading and verifying the update. Please keep the app open."
        case .restartRequired:
            return "The update is installed. Restart Rimeo Agent to continue."
        case .error(let text):
            return text
        case .clear:
            return ""
        }
    }

    private func retryCheck() {
        guard !isWorking else { return }
        isWorking = true
        appState.componentGateState = .checking
        Task {
            do {
                let missing = try await ComponentManager.shared.checkMissing()
                await MainActor.run {
                    isWorking = false
                    if missing.isEmpty {
                        appState.componentGateState = .clear
                        NotificationCenter.default.post(name: .componentGateCleared, object: nil)
                    } else {
                        appState.componentGateState = .required(missing)
                    }
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    appState.componentGateState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func install(_ components: [ComponentInfo]) {
        guard !isWorking else { return }
        isWorking = true
        appState.componentGateState = .downloading(0, "Installing update…")

        Task {
            do {
                try await ComponentManager.shared.download(components: components) { progress, label in
                    Task { @MainActor in
                        appState.componentGateState = .downloading(progress, label)
                    }
                }
                await MainActor.run {
                    isWorking = false
                    appState.componentGateState = .restartRequired
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    appState.componentGateState = .error(error.localizedDescription)
                }
            }
        }
    }
}

extension Notification.Name {
    static let componentGateCleared = Notification.Name("RimeoComponentGateCleared")
}

extension NSApplication {
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", Bundle.main.bundleURL.path]
        do {
            try process.run()
        } catch {
            logger.error("Relaunch failed: \(error)")
        }
        terminate(nil)
    }
}
