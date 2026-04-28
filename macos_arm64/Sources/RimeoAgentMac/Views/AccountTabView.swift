import SwiftUI

struct AccountTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var tokenInput = ""
    @State private var statusMsg = ""
    @State private var isLinking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Account")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(C.text)

                Text("Link this agent to your Rimeo account so the web app knows it's online.")
                    .font(.system(size: 13))
                    .foregroundColor(C.dim)

                Spacer().frame(height: 4)

                SectionLabel(text: "CONNECTION STATUS")
                connectionBadge

                if appState.cloudLinked {
                    HStack {
                        Button(action: doUnlink) {
                            HStack(spacing: 8) {
                                Image(systemName: "link.badge.minus")
                                Text("Delete Connection")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(C.red)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color(hex: "#3b1717"))
                            .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer().frame(height: 8)

                SectionLabel(text: "LINK TO ACCOUNT")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            StepRow(number: "1", text: "Open rimeo.app → Account → click «Generate Link Token».")
                            StepRow(number: "2", text: "Enter the 8-character code below and click Link.")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(C.bg)
                        .cornerRadius(16)

                        TextField("8-character code from web dashboard", text: $tokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)

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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var connectionBadge: some View {
        if appState.cloudLinked {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(C.green)
                    .font(.system(size: 16))
                Text("Linked as \(appState.cloudEmail.isEmpty ? DataStore.shared.data.cloud_url : appState.cloudEmail)")
                    .font(.system(size: 13))
                    .foregroundColor(C.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(hex: "#14532d"))
            .cornerRadius(16)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "link.badge.minus")
                    .foregroundColor(C.red)
                    .font(.system(size: 16))
                Text("Not linked to a cloud account")
                    .font(.system(size: 13))
                    .foregroundColor(C.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(hex: "#3b1717"))
            .cornerRadius(16)
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
