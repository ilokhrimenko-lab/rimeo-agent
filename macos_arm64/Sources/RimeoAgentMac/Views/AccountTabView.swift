import SwiftUI

struct AccountTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var tokenInput = ""
    @State private var statusMsg = ""
    @State private var isLinking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: "Account",
                             subtitle: "Link this agent to your Rimeo account so the web app knows it's online.")

                VStack(alignment: .leading, spacing: 11) {
                    SectionLabel(text: "CONNECTION STATUS")
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 16) {
                            connectionStatus
                            if appState.cloudLinked {
                                SecondaryButton(title: "Delete Connection",
                                                icon: "trash",
                                                action: doUnlink,
                                                destructive: true)
                            }
                        }
                        .padding(20)
                    }
                }

                VStack(alignment: .leading, spacing: 11) {
                    SectionLabel(text: "LINK TO ACCOUNT")
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 11) {
                                StepRow(number: "1", text: "On rimeo.app open Account and click Generate Link Token.")
                                StepRow(number: "2", text: "Enter the 8-character code below and click Link Agent.")
                            }

                            HStack(spacing: 10) {
                                Image(systemName: "link")
                                    .font(.system(size: 15))
                                    .foregroundColor(C.dim)
                                TextField("8-character code from web dashboard", text: $tokenInput)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundColor(C.text)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .background(C.field)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(C.brd, lineWidth: 1))

                            HStack(spacing: 16) {
                                if isLinking {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Linking…")
                                        .font(.system(size: 13))
                                        .foregroundColor(C.dim)
                                } else {
                                    RimeoButton(title: "Link Agent", icon: "link", color: C.acc, action: doLink)
                                }

                                if !statusMsg.isEmpty {
                                    Text(statusMsg)
                                        .font(.system(size: 13))
                                        .foregroundColor(statusMsg.hasPrefix("✓") ? C.green : C.red)
                                }
                            }
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
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if appState.cloudLinked {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(C.green)
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Linked to your account")
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
                Image(systemName: "link.badge.minus")
                    .foregroundColor(C.red)
                    .font(.system(size: 22))
                Text("Not linked to a cloud account")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(C.text)
                Spacer()
            }
        }
    }

    private func doLink() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMsg = "Please enter the link token."
            return
        }

        isLinking = true
        statusMsg = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let payload = try? JSONSerialization.data(withJSONObject: [
                "token": token,
                "cloud_url": AppConfig.shared.rimeoAppURL,
            ])
            let resp = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: "/api/link_account",
                queryParams: [:],
                headers: [:],
                body: payload ?? Data()
            ))

            DispatchQueue.main.async {
                isLinking = false
                if resp.status == 200 {
                    statusMsg = "✓ Linked successfully!"
                    tokenInput = ""
                } else {
                    let msg = (try? JSONSerialization.jsonObject(with: bodyData(resp)) as? [String: Any])?["detail"] as? String ?? "Error"
                    statusMsg = "Error: \(msg)"
                }
            }
        }
    }

    private func doUnlink() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: "/api/unlink_account",
                queryParams: [:],
                headers: [:],
                body: Data()
            ))
        }
    }

    private func bodyData(_ resp: HTTPResponse) -> Data {
        if case .data(let data) = resp.body { return data }
        return Data()
    }
}
