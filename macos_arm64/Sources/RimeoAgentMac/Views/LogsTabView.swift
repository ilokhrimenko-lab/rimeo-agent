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

    @State private var updateState: UpdateCheckState = .idle
    @State private var theme = ThemeManager.shared.theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(
                    title: "Settings",
                    subtitle: "Manage how the Rimeo agent runs on this Mac.",
                    trailing: AnyView(versionPill)
                )

                appearanceSection
                agentSettingsSection
                updateSection
                reportSection
                cacheSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 30)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            reloadSettingsFromStore()
            refreshCacheSize()
        }
    }

    private var versionPill: some View {
        Text(AppConfig.shared.displayVersion)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(C.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(C.chip)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "APPEARANCE")
            HStack(spacing: 4) {
                themeSegment(.auto,  "Auto",  "circle.lefthalf.filled")
                themeSegment(.light, "Light", "sun.max")
                themeSegment(.dark,  "Dark",  "moon")
            }
            .padding(4)
            .background(C.segTrack)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .fixedSize()

            Text("Auto follows your macOS appearance. Light or Dark forces a fixed theme.")
                .font(.system(size: 13))
                .foregroundColor(C.dim)
        }
    }

    @ViewBuilder
    private func themeSegment(_ value: AppTheme, _ label: String, _ icon: String) -> some View {
        let selected = theme == value
        Button {
            theme = value
            ThemeManager.shared.setTheme(value)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(label).font(.system(size: 14, weight: selected ? .semibold : .medium))
            }
            .foregroundColor(selected ? C.text : C.secondary)
            .frame(height: 40)
            .padding(.horizontal, 18)
            .background(selected ? C.segActive : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Agent settings

    private var agentSettingsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "AGENT SETTINGS")
            SurfaceCard {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow("Open Rimeo agent at system startup",
                               $launchAtLoginEnabled, applyLaunchAtLogin)
                    rowDivider
                    settingRow("Always show Rimeo agent icon in the Dock",
                               $showInDockEnabled, applyShowInDock)
                    rowDivider
                    settingRow("Keep disk access alive for 24/7 background work",
                               $keepAlive247Enabled, applyKeepAlive)

                    if !settingsStatus.isEmpty {
                        Text(settingsStatus)
                            .font(.system(size: 12))
                            .foregroundColor(settingsStatus.hasPrefix("✓") ? C.green : C.red)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func settingRow(_ title: String, _ binding: Binding<Bool>, _ action: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                action(newValue)
            }
        )) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(C.text)
        }
        .toggleStyle(RimeoCheckboxStyle())
        .frame(height: 52)
    }

    private var rowDivider: some View {
        Rectangle().fill(C.cardBrd).frame(height: 1)
    }

    // MARK: - Software update

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "SOFTWARE UPDATE")
            SurfaceCard {
                updateCheckContent
                    .padding(20)
            }
        }
    }

    private func updateIconBox(_ system: String, tint: Color, bg: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 19))
            .foregroundColor(tint)
            .frame(width: 38, height: 38)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    @ViewBuilder
    private var updateCheckContent: some View {
        switch updateState {
        case .idle:
            HStack(spacing: 14) {
                updateIconBox("arrow.triangle.2.circlepath", tint: C.accText, bg: C.accSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Software updates")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.text)
                    Text("Check whether a newer build is available")
                        .font(.system(size: 13))
                        .foregroundColor(C.dim)
                }
                Spacer()
                SecondaryButton(title: "Check for Updates", icon: nil, action: runUpdateCheck)
            }

        case .checking:
            HStack(spacing: 14) {
                updateIconBox("arrow.triangle.2.circlepath", tint: C.accText, bg: C.accSoft)
                ProgressView().scaleEffect(0.7)
                Text("Checking for updates…")
                    .font(.system(size: 14))
                    .foregroundColor(C.secondary)
                Spacer()
            }

        case .upToDate:
            HStack(spacing: 14) {
                updateIconBox("checkmark", tint: C.green, bg: C.greenSoft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rimeo agent is up to date")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.text)
                    Text(AppConfig.shared.displayVersion)
                        .font(.system(size: 13))
                        .foregroundColor(C.dim)
                }
                Spacer()
                SecondaryButton(title: "Check Again", icon: nil, action: runUpdateCheck)
            }

        case .available(let info):
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    updateIconBox("arrow.down.circle.fill", tint: C.accText, bg: C.accSoft)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update available: \(info.version)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(C.text)
                        if !info.notes.isEmpty {
                            Text(info.notes)
                                .font(.system(size: 12))
                                .foregroundColor(C.dim)
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    RimeoButton(title: "Update Now", icon: "arrow.down.circle", color: C.acc) {
                        (NSApp.delegate as? AppDelegate)?.triggerUpdate(info)
                    }
                    SecondaryButton(title: "On Next Launch", icon: "clock") {
                        UpdateChecker.shared.setPending(info)
                        updateState = .scheduled(info.version)
                    }
                }
            }

        case .scheduled(let version):
            HStack(spacing: 14) {
                updateIconBox("clock.fill", tint: C.amber, bg: C.amber.opacity(0.14))
                Text("Will update to \(version) on next launch")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.text)
                Spacer()
                SecondaryButton(title: "Cancel", icon: "xmark") {
                    UpdateChecker.shared.clearPending()
                    updateState = .idle
                }
            }
        }
    }

    // MARK: - Report a bug

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "REPORT A BUG")
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Describe the issue — the last 200 log lines are attached automatically.")
                        .font(.system(size: 13))
                        .foregroundColor(C.secondary)

                    TextEditor(text: $bugDesc)
                        .font(.system(size: 13))
                        .foregroundColor(C.text)
                        .hideScrollBackground()
                        .frame(minHeight: 90, maxHeight: 140)
                        .padding(8)
                        .background(C.field)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(C.cardBrd, lineWidth: 1))

                    HStack(spacing: 10) {
                        if isSending {
                            ProgressView().scaleEffect(0.7)
                            Text("Sending…")
                                .font(.system(size: 13))
                                .foregroundColor(C.dim)
                        } else {
                            RimeoButton(title: "Send Report", icon: "paperplane.fill", color: C.acc, action: sendBugReport)
                        }
                        SecondaryButton(title: "Copy Log", icon: "doc.on.doc", action: copyLogs)
                        SecondaryButton(title: "Open Log", icon: "doc.text", action: openLogFile)
                        Spacer()
                    }

                    if !bugStatus.isEmpty {
                        Text(bugStatus)
                            .font(.system(size: 13))
                            .foregroundColor(bugStatus.hasPrefix("✓") ? C.green : C.red)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "CACHE")
            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Converted audio, waveforms and artwork are stored here so tracks load instantly on repeat plays.")
                        .font(.system(size: 13))
                        .foregroundColor(C.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: "%.2f GB used", cacheSize))
                                .font(.system(size: 22, weight: .heavy))
                                .foregroundColor(C.text)
                            Spacer()
                            Text("of \(Int(Double(maxCacheGB) ?? 3)) GB max")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(C.dim)
                        }
                        cacheBar
                    }

                    rowDivider

                    HStack(spacing: 14) {
                        SecondaryButton(title: "Clear Cache", icon: "trash", action: clearCache, destructive: true)

                        if !cacheStatus.isEmpty {
                            Text(cacheStatus)
                                .font(.system(size: 12))
                                .foregroundColor(cacheStatus.hasPrefix("✓") ? C.green : C.red)
                        }

                        Spacer()

                        Text("Max cache")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(C.secondary)

                        HStack(spacing: 6) {
                            TextField("3", text: $maxCacheGB)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(C.text)
                                .frame(width: 40)
                            Text("GB")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(C.dim)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(C.field)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(C.brd, lineWidth: 1))

                        RimeoButton(title: "Save", icon: nil, color: C.acc, action: saveMaxCache)
                    }
                }
                .padding(20)
            }
        }
    }

    private var cacheBar: some View {
        let fill = cacheProgress > 0.9 ? C.red : (cacheProgress > 0.7 ? C.amber : C.acc)
        return ZStack(alignment: .leading) {
            Capsule().fill(C.chip).frame(height: 8)
            GeometryReader { geo in
                Capsule()
                    .fill(fill)
                    .frame(width: max(0, geo.size.width * cacheProgress), height: 8)
            }
            .frame(height: 8)
        }
        .frame(height: 8)
    }

    // MARK: - Settings actions

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
        cacheStatus = "Applying limit…"
        DispatchQueue.global(qos: .utility).async {
            CacheManager.shared.enforceLimit()
            DispatchQueue.main.async {
                cacheStatus = "✓ Max cache set to \(value) GB"
                refreshCacheSize()
            }
        }
    }

    private func runUpdateCheck() {
        updateState = .checking
        UpdateChecker.shared.forceCheckAsync { info in
            DispatchQueue.main.async {
                if let info {
                    updateState = .available(info)
                } else {
                    updateState = .upToDate
                }
            }
        }
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

private enum UpdateCheckState {
    case idle
    case checking
    case upToDate
    case available(UpdateInfo)
    case scheduled(String)
}
