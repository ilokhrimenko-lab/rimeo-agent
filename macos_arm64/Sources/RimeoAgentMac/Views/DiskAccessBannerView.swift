import SwiftUI
import AppKit

struct DiskAccessBannerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            C.bg.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 32))
                            .foregroundColor(C.acc)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Full Disk Access Required")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(C.text)
                            Text("Rimeo Agent needs Full Disk Access to read music files from external drives and all locations.")
                                .font(.system(size: 13))
                                .foregroundColor(C.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        StepRow(number: "1", text: "Click «Open Privacy Settings» below.")
                        StepRow(number: "2", text: "In the list, find «RimeoAgent» and enable it.")
                        StepRow(number: "3", text: "Restart Rimeo Agent.")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(C.bg)
                    .cornerRadius(12)

                    HStack(spacing: 12) {
                        Button(action: openPrivacySettings) {
                            HStack(spacing: 6) {
                                Image(systemName: "gear")
                                    .font(.system(size: 13))
                                Text("Open Privacy Settings")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(C.acc)
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)

                        Button(action: { appState.showDiskAccessBanner = false }) {
                            Text("Dismiss")
                                .font(.system(size: 13))
                                .foregroundColor(C.dim)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(C.surf)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.brd, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(28)
                .background(C.surf)
                .cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
                .frame(maxWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
