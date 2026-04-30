import SwiftUI

struct AnalysisTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var resultRows: [AnalysisRow] = []
    @State private var isAnalyzing = false
    @State private var stopRequested = false
    @State private var availableCount = 0
    @State private var analyzedCount = 0
    @State private var notAnalyzedCount = 0
    @State private var unavailableCount = 0

    struct AnalysisRow: Identifiable {
        let id: String
        let title: String
        let artist: String
        let segStart: Double?
        let segEnd: Double?
        let hasClap: Bool
        let pending: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Analysis")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(C.text)

                Text("Extracts CLAP audio embeddings from the best 30s segment of each track.")
                    .font(.system(size: 13))
                    .foregroundColor(C.dim)

                Spacer().frame(height: 4)

                SectionLabel(text: "ANALYSIS ENGINE")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundColor(C.dim)

                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                            .accentColor(C.acc)
                            .frame(maxWidth: 400)

                        HStack(spacing: 12) {
                            if !isAnalyzing {
                                RimeoButton(title: "Start Analysis",
                                            icon: "play.circle",
                                            color: C.acc,
                                            action: startAnalysis)
                            } else {
                                RimeoButton(title: "Stop",
                                            icon: "stop.circle",
                                            color: Color(hex: "#ef4444"),
                                            action: stopAnalysis)
                            }
                        }
                    }
                    .padding(20)
                }

                SectionLabel(text: "RESULTS")

                VStack(spacing: 0) {
                    ForEach(resultRows) { row in
                        AnalysisResultRow(row: row)
                    }
                }
                .background(C.surf)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadExistingRows()
            isAnalyzing = appState.analysisRunning
        }
        .onChange(of: appState.analysisRunning) { newValue in
            isAnalyzing = newValue
            if !newValue { loadExistingRows() }
        }
    }

    private var progressValue: Double {
        guard appState.analysisTotal > 0 else { return appState.analysisDone > 0 ? 1.0 : 0.0 }
        return Double(appState.analysisDone) / Double(max(appState.analysisTotal, 1))
    }

    private var statusText: String {
        if stopRequested { return "Stopping…" }
        if isAnalyzing || appState.analysisRunning {
            let current = min(max(appState.analysisDone + 1, 1), max(appState.analysisTotal, 1))
            return "Analyzing \(current) / \(max(appState.analysisTotal, 0)): \(appState.analysisCurrent)"
        }
        if availableCount > 0, notAnalyzedCount == 0 {
            if unavailableCount > 0 {
                return "All available tracks analyzed — \(analyzedCount) analyzed, \(unavailableCount) unavailable"
            }
            return "All tracks analyzed — \(analyzedCount) analyzed"
        }
        if availableCount > 0 {
            return "\(notAnalyzedCount) tracks not analyzed — \(analyzedCount) analyzed, \(unavailableCount) unavailable"
        }
        return "Ready"
    }

    private func startAnalysis() {
        guard !isAnalyzing else { return }
        stopRequested = false
        isAnalyzing = true
        resultRows.removeAll()
        DispatchQueue.global(qos: .utility).async {
            let response = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: "/api/analysis/start",
                queryParams: [:],
                headers: [:],
                body: Data()
            ))
            if response.status != 200 {
                DispatchQueue.main.async {
                    isAnalyzing = false
                }
            }
        }
    }

    private func stopAnalysis() {
        stopRequested = true
        DispatchQueue.global(qos: .utility).async {
            _ = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: "/api/analysis/stop",
                queryParams: [:],
                headers: [:],
                body: Data()
            ))
        }
    }

    private func loadExistingRows() {
        DispatchQueue.global(qos: .userInitiated).async {
            let library = RekordboxParser.shared.parse()
            let store = AnalysisEngine.shared.storeSnapshot()
            var rows = [AnalysisRow]()
            var seen = [String: Track]()
            library.tracks.forEach { seen[$0.id] = $0 }
            let uniqueTracks = Array(seen.values)
            let availableIDs = Set(
                uniqueTracks
                    .filter { FileManager.default.fileExists(atPath: $0.location) }
                    .map { $0.id }
            )
            for track in library.tracks {
                guard let feat = store[track.id] else { continue }
                rows.append(AnalysisRow(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    segStart: feat.segment_start,
                    segEnd: feat.segment_end,
                    hasClap: false,
                    pending: false
                ))
            }
            let analyzedAvailable = store.keys.filter { availableIDs.contains($0) }.count
            let notAnalyzed = max(0, availableIDs.count - analyzedAvailable)
            let unavailable = max(0, uniqueTracks.count - availableIDs.count)
            DispatchQueue.main.async {
                resultRows = rows
                availableCount = availableIDs.count
                analyzedCount = analyzedAvailable
                notAnalyzedCount = notAnalyzed
                unavailableCount = unavailable
            }
        }
    }
}

struct AnalysisResultRow: View {
    let row: AnalysisTabView.AnalysisRow

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.text)
                    .lineLimit(1)
                Text(row.artist)
                    .font(.system(size: 11))
                    .foregroundColor(C.dim)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if row.pending {
                Text("pending")
                    .font(.system(size: 11))
                    .foregroundColor(C.dim)
                    .italic()
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(C.dim)
            } else {
                Text("\(row.segStart ?? 0, specifier: "%.0f")s – \(row.segEnd ?? 0, specifier: "%.0f")s")
                    .font(.system(size: 11))
                    .foregroundColor(C.dim)
                Text(row.hasClap ? "CLAP ✓" : "analyzed")
                    .font(.system(size: 11))
                    .foregroundColor(row.hasClap ? C.acc : C.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(row.hasClap ? Color(hex: "#1e3a5f") : Color(hex: "#052e16"))
                    .cornerRadius(16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(Rectangle().frame(height: 1).foregroundColor(C.brd), alignment: .bottom)
    }
}
