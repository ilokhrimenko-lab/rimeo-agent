import SwiftUI
import AppKit

struct PairingTabView: View {
    @EnvironmentObject var appState: AppState
    /// JSON payload the Rimeo iOS app expects: {"url":..,"code":..,"agent_id":..}
    @State private var qrString = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: "Pairing",
                             subtitle: "Connect your music to the web player and the Rimeo iOS app.")

                VStack(alignment: .leading, spacing: 11) {
                    SectionLabel(text: "WEB BROWSER")
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("To listen to your music from any web browser")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(C.text)

                            VStack(alignment: .leading, spacing: 11) {
                                StepRow(number: "1", text: "Open rimeo.app and log in to your account.")
                                StepRow(number: "2", text: "Go to Account, then click Generate Link Token.")
                                StepRow(number: "3", text: "Enter the token in the Agent's Account tab and press Link.")
                            }

                            browserStatus
                        }
                        .padding(20)
                    }
                }

                VStack(alignment: .leading, spacing: 11) {
                    SectionLabel(text: "RIMEO iOS APP")
                    SurfaceCard {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("To use the Rimeo iOS app on your iPhone")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(C.text)

                                VStack(alignment: .leading, spacing: 11) {
                                    StepRow(number: "1", text: "Open the Rimeo iOS app on your iPhone.")
                                    StepRow(number: "2", text: "Tap Pair and scan the QR code shown here.")
                                    StepRow(number: "3", text: "Log in to your account — your library syncs automatically.")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(spacing: 12) {
                                QRCodeView(string: qrString, size: 132)
                                    .padding(14)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(C.brd, lineWidth: 1))

                                SecondaryButton(title: "Refresh QR", icon: "arrow.clockwise") {
                                    refreshPairing()
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .frame(width: 164)
                        }
                        .padding(20)
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
        .onAppear { refreshPairing() }
    }

    /// Requests a fresh pairing code from the agent and builds the exact JSON
    /// payload the Rimeo iOS scanner decodes into `PairingInfo`.
    private func refreshPairing() {
        DispatchQueue.global(qos: .userInitiated).async {
            let resp = APIRouter.shared.route(HTTPRequest(
                method: "GET",
                path: "/api/pairing_info",
                queryParams: [:],
                headers: [:],
                body: Data()
            ))
            guard case .data(let data) = resp.body,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let url = obj["local_url"] as? String,
                  let code = obj["code"] as? String else { return }
            let agentID = (obj["agent_id"] as? String) ?? AppConfig.shared.agentID
            // v2 QR payload (LAN tier): embed the PSK + LAN endpoint so iOS can talk
            // to us directly on the local network. url/code kept for back-compat.
            var dict: [String: Any] = ["url": url, "code": code, "agent_id": agentID]
            for k in ["v", "secret", "hostname", "lan_ip", "lan_port"] {
                if let val = obj[k] { dict[k] = val }
            }
            let payload = (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? #"{"url":"\#(url)","code":"\#(code)","agent_id":"\#(agentID)"}"#
            DispatchQueue.main.async { qrString = payload }
        }
    }

    @ViewBuilder
    private var browserStatus: some View {
        if appState.cloudLinked {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(C.green)
                    .font(.system(size: 16))
                Text("Connected as \(appState.cloudEmail.isEmpty ? DataStore.shared.data.cloud_url : appState.cloudEmail)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(C.green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(C.greenSoft)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            HStack(spacing: 9) {
                Image(systemName: "link.badge.minus")
                    .foregroundColor(C.dim)
                    .font(.system(size: 15))
                Text("Not connected — link your agent in the Account tab")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(C.chip)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
}
