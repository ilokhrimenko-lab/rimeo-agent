import SwiftUI

// Devices tab (login model): everything signed in to the account connects
// automatically — no pairing codes, no QR. Replaces the old token/QR pairing UI.
struct PairingTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: "Devices",
                             subtitle: "Everything signed in to your Rimeo account connects automatically — no codes, no QR.")

                VStack(alignment: .leading, spacing: 11) {
                    SectionLabel(text: "CONNECTED")
                    SurfaceCard {
                        VStack(spacing: 0) {
                            deviceRow(icon: "desktopcomputer",
                                      title: "This computer",
                                      subtitle: "Your library lives here",
                                      pill: ("Active", true))
                            divider
                            deviceRow(icon: "globe",
                                      title: "rimeo.app",
                                      subtitle: "Player in your account",
                                      pill: appState.cloudLinked ? ("Connected", true) : ("Not connected", false))
                            divider
                            deviceRow(icon: "iphone",
                                      title: "Your phone",
                                      subtitle: "Sign in with the Rimeo app to connect",
                                      pill: ("Not signed in", false))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 30)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(C.cardBrd).frame(height: 1)
    }

    private func deviceRow(icon: String, title: String, subtitle: String,
                           pill: (text: String, ok: Bool)) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(pill.ok ? C.accSoft : C.chip)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(pill.ok ? C.accText : C.dim)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(C.text)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(C.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            statusPill(pill.text, ok: pill.ok)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private func statusPill(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            if ok {
                Circle().fill(C.green).frame(width: 7, height: 7)
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ok ? C.green : C.dim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ok ? C.greenSoft : C.chip)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
