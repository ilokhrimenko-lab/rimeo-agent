import SwiftUI
import AppKit

// Account tab (login model). Merges the former standalone "Devices" tab: the
// account status + sign-out live alongside the list of everything signed in to
// the account (this computer, rimeo.app, phone). Everything on the same account
// connects automatically — no pairing codes, no QR.
struct AccountTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var showPhoneQR = false

    private var phoneAppURL: String { "\(AppConfig.shared.rimeoAppURL)/open" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: "Account",
                             subtitle: "Everything signed in to your Rimeo account connects automatically — no codes, no QR.")

                VStack(alignment: .leading, spacing: 11) {
                    SectionLabel(text: "ACCOUNT")
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 16) {
                            connectionStatus
                            if appState.cloudLinked {
                                SecondaryButton(title: "Sign out",
                                                icon: "rectangle.portrait.and.arrow.right",
                                                action: doSignOut,
                                                destructive: true)
                            }
                        }
                        .padding(20)
                    }
                }

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
                                      subtitle: appState.phoneConnected
                                          ? "Signed in to the Rimeo app"
                                          : "Sign in with the Rimeo app to connect",
                                      pill: appState.phoneConnected
                                          ? ("Connected", true)
                                          : ("Not connected", false))
                        }
                    }

                    if !appState.phoneConnected {
                        Button(action: { showPhoneQR = true }) {
                            HStack(spacing: 7) {
                                Image(systemName: "qrcode")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Get the app for your phone")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(C.accText)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                        .popover(isPresented: $showPhoneQR, arrowEdge: .bottom) {
                            phoneQRPopover
                        }
                    }

                    Text("One agent stays active per account — signing in on another computer signs this one out.")
                        .font(.system(size: 12))
                        .foregroundColor(C.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
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

    @ViewBuilder
    private var connectionStatus: some View {
        if appState.cloudLinked {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(C.green)
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in to Rimeo")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(C.text)
                    Text(appState.cloudEmail.isEmpty ? DataStore.shared.data.cloud_url : appState.cloudEmail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(C.secondary)
                }
                Spacer()
            }
        } else {
            HStack(spacing: 11) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundColor(C.red)
                    .font(.system(size: 22))
                Text("Not signed in")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(C.text)
                Spacer()
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(C.cardBrd).frame(height: 1)
    }

    private var phoneQRPopover: some View {
        VStack(spacing: 14) {
            Text("Get the Rimeo app")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(C.text)
            Text("Scan with your phone's camera")
                .font(.system(size: 12))
                .foregroundColor(C.secondary)
            QRCodeView(string: phoneAppURL, size: 180)
                .padding(8)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button(action: openPhoneApp) {
                Text("Open in browser instead")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(C.accText)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(width: 260)
        .background(C.bg)
    }

    private func openPhoneApp() {
        if let url = URL(string: phoneAppURL) {
            NSWorkspace.shared.open(url)
        }
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

    private func doSignOut() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: "/api/unlink_account",
                queryParams: [:],
                headers: [:],
                body: Data(),
                trusted: true   // in-process UI call — not socket traffic
            ))
        }
    }
}
