import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryTabView: View {
    @State private var statusMsg = ""
    @State private var dbAgeText = ""
    @State private var xmlPath = AppConfig.shared.xmlPath
    @State private var masterDBErr: String? = nil

    @State private var dbEnabled  = AppConfig.shared.dbSourceEnabled
    @State private var xmlEnabled = AppConfig.shared.xmlSourceEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: "Library",
                             subtitle: "Turn on the sources Rimeo reads your tracks from — you can use both at once.")

                topTabs

                dbCard

                if let err = masterDBErr { masterDBWarning(err) }

                xmlCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 30)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshDatabaseAge() }
    }

    // MARK: - Top tabs

    private var topTabs: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 28) {
                VStack(spacing: 12) {
                    Text("Rekordbox")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(C.text)
                    Rectangle().fill(C.acc).frame(height: 2).clipShape(Capsule())
                }
                .fixedSize()

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Other DJ software")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(C.faint)
                        Text("SOON")
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.6)
                            .foregroundColor(C.dim)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(C.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Rectangle().fill(Color.clear).frame(height: 2)
                }
                .fixedSize()

                Spacer()
            }
            Rectangle().fill(C.brd).frame(height: 1)
        }
    }

    // MARK: - Rekordbox database card

    private var dbCard: some View {
        let exists = AppConfig.shared.dbExists
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                sourceHeader(
                    icon: "cylinder.split.1x2",
                    iconTint: C.accText,
                    iconBg: C.accSoft,
                    title: "Rekordbox database",
                    statusDot: dbEnabled ? (exists ? C.green : C.red) : C.dim,
                    statusText: dbEnabled ? (exists ? "Connected" : "Not found") : "Off",
                    statusColor: dbEnabled ? (exists ? C.green : C.red) : C.dim,
                    isOn: $dbEnabled,
                    onToggle: { v in
                        AppConfig.shared.setDBSourceEnabled(v)
                        RekordboxParser.shared.invalidateCache()
                    }
                )

                VStack(alignment: .leading, spacing: 14) {
                    Text(AppConfig.shared.dbPath)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(C.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !dbAgeText.isEmpty {
                        Text(dbAgeText)
                            .font(.system(size: 13))
                            .foregroundColor(C.dim)
                    }

                    if !statusMsg.isEmpty {
                        Text(statusMsg)
                            .font(.system(size: 13))
                            .foregroundColor(C.secondary)
                    }

                    RimeoButton(title: "Reload Library",
                                icon: "arrow.clockwise",
                                color: C.acc,
                                action: reloadLibrary)
                }
                .opacity(dbEnabled ? 1 : 0.5)
            }
            .padding(20)
        }
    }

    // MARK: - XML card

    private var xmlCard: some View {
        let xmlExists = !xmlPath.isEmpty && FileManager.default.fileExists(atPath: xmlPath)
        let statusText: String
        let statusColor: Color
        if !xmlEnabled {
            statusText = "Off"; statusColor = C.dim
        } else if xmlExists {
            statusText = "Configured"; statusColor = C.green
        } else if xmlPath.isEmpty {
            statusText = "No file selected"; statusColor = C.dim
        } else {
            statusText = "File not found"; statusColor = C.red
        }

        return SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                sourceHeader(
                    icon: "doc.text",
                    iconTint: C.dim,
                    iconBg: C.chip,
                    title: "Exported XML file",
                    statusDot: statusColor,
                    statusText: statusText,
                    statusColor: statusColor,
                    isOn: $xmlEnabled,
                    onToggle: { v in
                        AppConfig.shared.setXMLSourceEnabled(v)
                        RekordboxParser.shared.invalidateCache()
                    }
                )

                VStack(alignment: .leading, spacing: 14) {
                    if !xmlPath.isEmpty {
                        Text(xmlPath)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(C.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    SecondaryButton(
                        title: xmlPath.isEmpty ? "Select rekordbox.xml" : "Change XML Path",
                        icon: "folder",
                        action: pickXML
                    )
                }
                .opacity(xmlEnabled ? 1 : 0.5)
            }
            .padding(20)
        }
    }

    // MARK: - Source header row

    @ViewBuilder
    private func sourceHeader(icon: String,
                              iconTint: Color,
                              iconBg: Color,
                              title: String,
                              statusDot: Color,
                              statusText: String,
                              statusColor: Color,
                              isOn: Binding<Bool>,
                              onToggle: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(iconTint)
                .frame(width: 40, height: 40)
                .background(iconBg)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(C.text)
                HStack(spacing: 6) {
                    Circle().fill(statusDot).frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(statusColor)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                set: { newValue in
                    isOn.wrappedValue = newValue
                    onToggle(newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(RimeoSwitchStyle())
        }
    }

    private func masterDBWarning(_ err: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(C.amber)
                        .font(.system(size: 16))
                    Text("master.db could not be read")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(C.amber)
                }
                if err.contains("SQLCipher Python module missing") || err.contains("sqlcipher3") || err.contains("pysqlcipher3") {
                    Text("This Mac build could not open Rekordbox master.db because the SQLCipher helper is missing. As a temporary workaround, export XML from Rekordbox and enable it below.")
                        .font(.system(size: 13))
                        .foregroundColor(C.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(String(err.prefix(200)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(C.dim)
                        .lineLimit(3)
                }
            }
            .padding(18)
        }
    }

    // MARK: - Actions

    private func refreshDatabaseAge() {
        let path = AppConfig.shared.dbPath
        guard !path.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mdate = attrs[.modificationDate] as? Date else {
            dbAgeText = ""
            return
        }

        let age = Date().timeIntervalSince(mdate)
        let fmt = DateFormatter()
        fmt.dateFormat = "dd MMM yyyy, HH:mm"
        let updated = fmt.string(from: mdate)
        let ageLabel: String
        if age < 3600 {
            ageLabel = "\(Int(age / 60)) min ago"
        } else if age < 86400 {
            ageLabel = "\(Int(age / 3600)) h ago"
        } else {
            ageLabel = "\(Int(age / 86400)) days ago"
        }
        dbAgeText = "Last modified \(updated)  ·  \(ageLabel)"
    }

    private func reloadLibrary() {
        statusMsg = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async {
            RekordboxParser.shared.invalidateCache()
            let result = RekordboxParser.shared.parse()
            let err = RekordboxParser.shared.masterDBError
            let source = result.source ?? (AppConfig.shared.dbExists ? "db" : "xml")
            DispatchQueue.main.async {
                masterDBErr = err
                if result.tracks.count > 0 {
                    statusMsg = "✓ \(result.tracks.count) tracks, \(result.playlists.count) playlists  (\(source))"
                } else if err != nil {
                    statusMsg = "0 tracks — library source could not be read"
                } else {
                    statusMsg = "0 tracks loaded"
                }
                refreshDatabaseAge()
            }
        }
    }

    private func pickXML() {
        let panel = NSOpenPanel()
        panel.title = "Select rekordbox.xml"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            AppConfig.shared.setXMLPath(url.path)
            RekordboxParser.shared.invalidateCache()
            xmlPath = url.path
            if !xmlEnabled {
                xmlEnabled = true
                AppConfig.shared.setXMLSourceEnabled(true)
            }
            reloadLibrary()
        }
    }
}
