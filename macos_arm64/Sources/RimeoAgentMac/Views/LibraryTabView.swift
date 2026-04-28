import SwiftUI

struct LibraryTabView: View {
    @State private var statusMsg = ""
    @State private var dbAgeText = ""
    @State private var dbAgeColor = C.dim

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
            let source = result.source ?? (AppConfig.shared.dbExists ? "db" : "xml")
            DispatchQueue.main.async {
                statusMsg = "✓ \(result.tracks.count) tracks, \(result.playlists.count) playlists  (\(source))"
                refreshDatabaseAge()
            }
        }
    }
}
