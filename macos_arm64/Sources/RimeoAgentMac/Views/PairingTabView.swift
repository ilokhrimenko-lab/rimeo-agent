import SwiftUI
import AppKit

struct PairingTabView: View {
    @EnvironmentObject var appState: AppState

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

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func openRimeoApp() {
        NSWorkspace.shared.open(URL(string: AppConfig.shared.rimeoAppURL)!)
    }
}
