import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryTabView: View {
    @State private var statusMsg = ""
    @State private var dbAgeText = ""
    @State private var dbAgeColor = C.dim
    @State private var xmlPath = AppConfig.shared.xmlPath
    @State private var masterDBErr: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Library")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(C.text)

                Text("Reads your Rekordbox library automatically and serves tracks to rimeo.app.")
                    .font(.system(size: 13))
                    .foregroundColor(C.dim)

                Spacer().frame(height: 4)

                SectionLabel(text: "REKORDBOX DATABASE")

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: AppConfig.shared.dbExists ? "checkmark.circle" : "exclamationmark.triangle")
                                .foregroundColor(AppConfig.shared.dbExists ? C.green : C.red)
                                .font(.system(size: 18))
                            Text(AppConfig.shared.dbExists ? "Connected" : "Not found")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppConfig.shared.dbExists ? C.green : C.red)
                        }

                        Text(AppConfig.shared.dbPath)
                            .font(.system(size: 11))
                            .foregroundColor(C.dim)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if !dbAgeText.isEmpty {
                            Text(dbAgeText)
                                .font(.system(size: 12))
                                .foregroundColor(dbAgeColor)
                        }

                        if !statusMsg.isEmpty {
                            Text(statusMsg)
                                .font(.system(size: 13))
                                .foregroundColor(C.dim)
                        }

                        HStack(spacing: 16) {
                            RimeoButton(title: "Reload Library",
                                        icon: "arrow.clockwise",
                                        color: C.acc,
                                        action: reloadLibrary)
                        }
                    }
                    .padding(20)
                }

                // Warning when master.db can't be read
                if let err = masterDBErr {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(C.amber)
                                    .font(.system(size: 16))
                                Text("master.db could not be read")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(C.amber)
                            }
                            if err.contains("SQLCipher Python module missing") || err.contains("sqlcipher3") || err.contains("pysqlcipher3") {
                                Text("This Mac build could not open Rekordbox master.db because the SQLCipher helper is missing. As a temporary workaround, export XML from Rekordbox and select it below.")
                                    .font(.system(size: 12))
                                    .foregroundColor(C.dim)
                            } else {
                                Text(String(err.prefix(200)))
                                    .font(.system(size: 11))
                                    .foregroundColor(C.dim)
                                    .lineLimit(3)
                            }
                        }
                        .padding(16)
                    }
                }

                Spacer().frame(height: 4)

                SectionLabel(text: "REKORDBOX XML (ALTERNATIVE)")

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        let xmlExists = !xmlPath.isEmpty && FileManager.default.fileExists(atPath: xmlPath)
                        HStack(spacing: 8) {
                            Image(systemName: xmlExists ? "checkmark.circle" : (xmlPath.isEmpty ? "minus.circle" : "xmark.circle"))
                                .foregroundColor(xmlExists ? C.green : C.dim)
                                .font(.system(size: 18))
                            Text(xmlExists ? "XML configured" : (xmlPath.isEmpty ? "Not configured" : "File not found"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(xmlExists ? C.green : C.dim)
                        }

                        if !xmlPath.isEmpty {
                            Text(xmlPath)
                                .font(.system(size: 11))
                                .foregroundColor(C.dim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        RimeoButton(
                            title: xmlPath.isEmpty ? "Select rekordbox.xml" : "Change XML Path",
                            icon: "folder",
                            color: C.acc,
                            action: pickXML
                        )
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshDatabaseAge() }
    }

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
            dbAgeColor = C.dim
        } else if age < 86400 {
            ageLabel = "\(Int(age / 3600)) h ago"
            dbAgeColor = C.dim
        } else {
            ageLabel = "\(Int(age / 86400)) days ago"
            dbAgeColor = C.dim
        }
        dbAgeText = "Last modified: \(updated)  ·  \(ageLabel)"
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
            reloadLibrary()
        }
    }
}
