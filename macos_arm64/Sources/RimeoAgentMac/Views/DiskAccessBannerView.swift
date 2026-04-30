import SwiftUI
import AppKit

struct DiskAccessBannerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: appState.fdaResetAfterUpdate ? "arrow.clockwise.circle" : "lock.shield")
                    .font(.system(size: 32))
                    .foregroundColor(C.acc)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.fdaResetAfterUpdate
                         ? "Full Disk Access Reset After Update"
                         : "Full Disk Access Required")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(C.text)
                    Text(appState.fdaResetAfterUpdate
                         ? "macOS resets Full Disk Access when an app updates. You need to re-grant it."
                         : "Rimeo Agent needs Full Disk Access to read music files from external drives and all locations.")
                        .font(.system(size: 13))
                        .foregroundColor(C.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if appState.fdaResetAfterUpdate {
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: "1", text: "Click «Open Privacy Settings» below.")
                    StepRow(number: "2", text: "Find the old Rimeo Agent entry and click – to remove it.")
                    StepRow(number: "3", text: "Add the new Rimeo Agent by dragging it into the list or clicking +.")
                    StepRow(number: "4", text: "Restart Rimeo Agent.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(C.bg)
                .cornerRadius(12)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    StepRow(number: "1", text: "Click «Open Privacy Settings» below.")
                    StepRow(number: "2", text: "Find «RimeoAgent» in the list and enable it.")
                    StepRow(number: "3", text: "Restart Rimeo Agent.")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(C.bg)
                .cornerRadius(12)
            }

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

                Button(action: { appState.dismissDiskAccessBanner() }) {
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
        .frame(width: 480)
        .background(C.bg)
    }

    private func openPrivacySettings() {
        if #available(macOS 13, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
