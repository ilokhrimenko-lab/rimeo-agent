import SwiftUI
import AppKit

struct PairingTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var cacheSize: Double = 0
    @State private var maxCacheGB: String = "3"
    @State private var cacheStatus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pairing")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(C.text)

                Spacer().frame(height: 4)

                SectionLabel(text: "WEB BROWSER")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("To listen to your music from any web browser:")
                            .font(.system(size: 13))
                            .foregroundColor(C.text)

                        VStack(alignment: .leading, spacing: 8) {
                            StepRow(number: "1", text: "Open rimeo.app and log in to your account.")
                            StepRow(number: "2", text: "Go to Account → click «Generate Link Token».")
                            StepRow(number: "3", text: "Enter the token in the Agent's Account tab and press Link.")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(C.bg)
                        .cornerRadius(16)

                        browserStatus
                    }
                    .padding(20)
                }

                Spacer().frame(height: 4)

                SectionLabel(text: "iOS APP")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("To use the Rimeo iOS app on your iPhone:")
                            .font(.system(size: 13))
                            .foregroundColor(C.text)

                        VStack(alignment: .leading, spacing: 8) {
                            StepRow(number: "1", text: "Open the Rimeo iOS app on your iPhone.")
                            StepRow(number: "2", text: "Tap «Pair» and scan the QR code shown on rimeo.app.")
                            StepRow(number: "3", text: "Log in to your account — your library will sync automatically.")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(C.bg)
                        .cornerRadius(16)

                        Button(action: openRimeoApp) {
                            HStack(spacing: 8) {
                                Image(systemName: "safari")
                                Text("Open rimeo.app")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(C.acc)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(C.surf)
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                }

                Spacer().frame(height: 4)

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
                                    .tint(cacheProgress > 0.9 ? C.red : (cacheProgress > 0.7 ? C.amber : C.acc))
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
        .onAppear { refreshCacheSize() }
    }

    @ViewBuilder
    private var browserStatus: some View {
        if appState.cloudLinked {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(C.green)
                    .font(.system(size: 14))
                Text("Connected as \(appState.cloudEmail.isEmpty ? DataStore.shared.data.cloud_url : appState.cloudEmail)")
                    .font(.system(size: 12))
                    .foregroundColor(C.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(hex: "#052e16"))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "#166534"), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "link.badge.minus")
                    .foregroundColor(C.dim)
                    .font(.system(size: 14))
                Text("Not connected — link your agent in the Account tab")
                    .font(.system(size: 12))
                    .foregroundColor(C.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(hex: "#1c1917"))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
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

    private func openRimeoApp() {
        NSWorkspace.shared.open(URL(string: AppConfig.shared.rimeoAppURL)!)
    }
}
