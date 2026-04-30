import SwiftUI
import AppKit

struct LogsTabView: View {
    @State private var launchAtLoginEnabled = AgentSettings.shared.launchAtLoginEnabled
    @State private var showInDockEnabled = AgentSettings.shared.showInDockEnabled
    @State private var keepAlive247Enabled = AgentSettings.shared.keepAlive247Enabled
    @State private var settingsStatus = ""

    @State private var bugDesc = ""
    @State private var bugStatus = ""
    @State private var isSending = false

    @State private var cacheSize: Double = 0
    @State private var maxCacheGB: String = "3"
    @State private var cacheStatus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Settings")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(C.text)
                    Spacer()
                    Text(AppConfig.shared.displayVersion)
                        .font(.system(size: 12))
                        .foregroundColor(C.dim)
                }

                Spacer().frame(height: 4)

                SectionLabel(text: "AGENT SETTINGS")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        settingToggleRow(
                            title: "Open RimeoAgent at system startup",
                            binding: $launchAtLoginEnabled,
                            action: applyLaunchAtLogin
                        )
                        settingToggleRow(
                            title: "Always show RimeoAgent icon in Dock",
                            binding: $showInDockEnabled,
                            action: applyShowInDock
                        )
                        settingToggleRow(
                            title: "Allow RimeoAgent to keep disk access alive for 24/7 work",
                            binding: $keepAlive247Enabled,
                            action: applyKeepAlive
                        )

                        if !settingsStatus.isEmpty {
                            Text(settingsStatus)
                                .font(.system(size: 12))
                                .foregroundColor(settingsStatus.hasPrefix("✓") ? C.green : C.red)
                        }
                    }
                    .padding(20)
                }

                SectionLabel(text: "REPORT A BUG")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The last 200 log lines will be attached automatically.")
                            .font(.system(size: 12))
                            .foregroundColor(C.dim)

                        TextEditor(text: $bugDesc)
                            .font(.system(size: 13))
                            .foregroundColor(C.text)
                            .frame(minHeight: 90, maxHeight: 140)
                            .padding(6)
                            .background(C.surf)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        HStack(spacing: 10) {
                            if isSending {
                                ProgressView().scaleEffect(0.7)
                                Text("Sending…")
                                    .font(.system(size: 13))
                                    .foregroundColor(C.dim)
                            } else {
                                RimeoButton(title: "Send Report", icon: "ladybug", color: C.acc, action: sendBugReport)
                            }
                            Spacer()
                            compactActionButton(title: "Copy Log", icon: "doc.on.doc", action: copyLogs)
                            compactActionButton(title: "Open Log", icon: "doc.text", action: openLogFile)
                        }
                        if !bugStatus.isEmpty {
                            Text(bugStatus)
                                .font(.system(size: 13))
                                .foregroundColor(bugStatus.hasPrefix("✓") ? C.green : C.red)
                        }
                    }
                    .padding(20)
                }

                SectionLabel(text: "CACHE")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The cache stores converted audio (WAV), waveform data and artwork so tracks load faster on repeat plays.")
                            .font(.system(size: 12))
                            .foregroundColor(C.dim)

                        Spacer().frame(height: 4)

                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(String(format: "%.2f GB used", cacheSize))
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(C.text)

                                ProgressView(value: cacheProgress)
                                    .progressViewStyle(.linear)
                                    .accentColor(cacheProgress > 0.9 ? C.red : (cacheProgress > 0.7 ? C.amber : C.acc))
                                    .frame(width: 280)

                                Text("of \(Int(Double(maxCacheGB) ?? 3)) GB max")
                                    .font(.system(size: 12))
                                    .foregroundColor(C.dim)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Max cache (GB)")
                                    .font(.system(size: 11))
                                    .foregroundColor(C.dim)

                                HStack(spacing: 8) {
                                    TextField("3", text: $maxCacheGB)
                                        .frame(width: 72)
                                        .textFieldStyle(.roundedBorder)
                                        .multilineTextAlignment(.center)

                                    RimeoButton(title: "Save", icon: nil, color: C.acc, action: saveMaxCache)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button(action: clearCache) {
                                HStack(spacing: 8) {
                                    Image(systemName: "trash")
                                    Text("Clear Cache")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundColor(C.red)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(C.surf)
                                .cornerRadius(16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "#7f1d1d"), lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            if !cacheStatus.isEmpty {
                                Text(cacheStatus)
                                    .font(.system(size: 12))
                                    .foregroundColor(cacheStatus.hasPrefix("✓") ? C.green : C.red)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            reloadSettingsFromStore()
            refreshCacheSize()
        }
    }

    @ViewBuilder
    private func compactActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(C.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(C.surf)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.brd, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingToggleRow(title: String, binding: Binding<Bool>, action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                action(newValue)
            }
        )) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(C.text)
        }
        .toggleStyle(.checkbox)
    }

    private func reloadSettingsFromStore() {
        launchAtLoginEnabled = AgentSettings.shared.launchAtLoginEnabled
        showInDockEnabled = AgentSettings.shared.showInDockEnabled
        keepAlive247Enabled = AgentSettings.shared.keepAlive247Enabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            try AgentSettings.shared.setLaunchAtLogin(enabled)
            settingsStatus = enabled ? "✓ Launch at login enabled" : "✓ Launch at login disabled"
        } catch {
            launchAtLoginEnabled = AgentSettings.shared.launchAtLoginEnabled
            settingsStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func applyShowInDock(_ enabled: Bool) {
        AgentSettings.shared.setShowInDock(enabled)
        settingsStatus = enabled ? "✓ Dock icon is enabled" : "✓ Dock icon is disabled"
    }

    private func applyKeepAlive(_ enabled: Bool) {
        AgentSettings.shared.setKeepAlive247(enabled)
        settingsStatus = enabled ? "✓ 24/7 keep-alive mode enabled" : "✓ 24/7 keep-alive mode disabled"
    }

    private func copyLogs() {
        let text = logger.lastLines(200)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        bugStatus = "✓ Log copied"
    }

    private func openLogFile() {
        NSWorkspace.shared.open(AppConfig.shared.logFile)
    }

    private var cacheProgress: Double {
        let maxGB = Double(maxCacheGB) ?? 3.0
        guard maxGB > 0 else { return 0 }
        return min(cacheSize / maxGB, 1.0)
    }

    private func refreshCacheSize() {
        let dir = AppConfig.shared.cacheDir
        let stored = Int(DataStore.shared.data.max_cache_gb)
        if stored > 0 { maxCacheGB = "\(stored)" }

        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) } ?? 0
                }
            }
            let gb = Double(total) / 1_073_741_824
            DispatchQueue.main.async { cacheSize = gb }
        }
    }

    private func clearCache() {
        cacheStatus = "Clearing…"
        DispatchQueue.global(qos: .utility).async {
            let dir = AppConfig.shared.cacheDir
            do {
                let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                for file in files { try? FileManager.default.removeItem(at: file) }
                DispatchQueue.main.async {
                    cacheStatus = "✓ Cache cleared"
                    refreshCacheSize()
                }
            } catch {
                DispatchQueue.main.async {
                    cacheStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveMaxCache() {
        let value = max(1, Int(maxCacheGB) ?? 3)
        DataStore.shared.update { $0.max_cache_gb = Double(value) }
        maxCacheGB = "\(value)"
        cacheStatus = "✓ Max cache set to \(value) GB"
    }

    private func sendBugReport() {
        let desc = bugDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else {
            bugStatus = "Please describe the issue."
            return
        }

        isSending = true
        bugStatus = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let payload = try? JSONSerialization.data(withJSONObject: ["description": desc])
            let resp = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: "/api/report_bug",
                queryParams: [:],
                headers: [:],
                body: payload ?? Data()
            ))

            DispatchQueue.main.async {
                isSending = false
                if resp.status == 200 {
                    bugStatus = "✓ Bug report sent!"
                    bugDesc = ""
                } else {
                    let msg = extractDetail(resp) ?? "Error \(resp.status)"
                    bugStatus = "Error: \(msg)"
                }
            }
        }
    }

    private func extractDetail(_ resp: HTTPResponse) -> String? {
        guard case .data(let data) = resp.body,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["detail"] as? String
    }
}

private struct SelectableTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 12, *) {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}
