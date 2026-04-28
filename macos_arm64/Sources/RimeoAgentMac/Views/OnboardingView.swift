import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var statusMsg = ""
    @State private var isError = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Rimeo Agent")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(C.text)

                Text("Rekordbox library not found at the default location.")
                    .font(.system(size: 14))
                    .foregroundColor(C.dim)

                Spacer().frame(height: 24)

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(C.amber)
                                .font(.system(size: 20))
                            Text("master.db not found")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(C.amber)
                        }

                        Text("Expected: ~/Library/Pioneer/rekordbox/master.db")
                            .font(.system(size: 12))
                            .foregroundColor(C.dim)

                        HStack(spacing: 10) {
                            Image(systemName: "info.circle")
                                .foregroundColor(C.acc)
                                .font(.system(size: 16))
                            Text("Make sure Rekordbox 6 or 7 is installed and launched at least once.")
                                .font(.system(size: 12))
                                .foregroundColor(C.dim)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(hex: "#0d2137"))
                        .cornerRadius(12)

                        Button(action: retryAutoDetect) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry auto-detect")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(C.text)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(C.surf)
                            .cornerRadius(16)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(24)
                }

                Spacer().frame(height: 16)

                Text("Or select the file manually:")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(C.text)

                Spacer().frame(height: 4)

                HStack(spacing: 16) {
                    onboardingOptionCard(
                        icon: "externaldrive",
                        title: "Rekordbox 6/7",
                        subtitle: "master.db  (recommended)",
                        primary: true,
                        buttonTitle: "Select master.db",
                        action: pickDB
                    )

                    onboardingOptionCard(
                        icon: "doc",
                        title: "Rekordbox XML",
                        subtitle: "rekordbox.xml  (fallback)",
                        primary: false,
                        buttonTitle: "Select .xml",
                        action: pickXML
                    )
                }

                if !statusMsg.isEmpty {
                    Text(statusMsg)
                        .font(.system(size: 13))
                        .foregroundColor(isError ? C.red : C.green)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func onboardingOptionCard(
        icon: String,
        title: String,
        subtitle: String,
        primary: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundColor(primary ? C.acc : C.dim)
                        .font(.system(size: 20))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(C.text)
                }

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(C.dim)

                Spacer().frame(height: 4)

                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text(buttonTitle)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(primary ? .white : C.text)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(primary ? C.acc : C.surf)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(primary ? Color.clear : C.brd, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func retryAutoDetect() {
        if AppConfig.shared.dbExists {
            appState.refreshLibrarySource()
            statusMsg = ""
            return
        }
        statusMsg = "Not found: \(AppConfig.shared.dbPath)"
        isError = true
    }

    private func pickDB() {
        let panel = NSOpenPanel()
        panel.title = "Select master.db"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["db"]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            appState.finishOnboarding(dbPath: url.path)
            statusMsg = ""
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
            appState.finishOnboarding(xmlPath: url.path)
            isError = false
            statusMsg = ""
        }
    }
}
