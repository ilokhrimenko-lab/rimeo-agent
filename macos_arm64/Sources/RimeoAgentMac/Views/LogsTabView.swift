import SwiftUI
import AppKit

struct LogsTabView: View {
    @State private var logText = ""
    @State private var bugDesc = ""
    @State private var bugStatus = ""
    @State private var isSending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Logs")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(C.text)

                Spacer().frame(height: 4)

                SectionLabel(text: "REPORT A BUG")
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The last 200 log lines will be attached automatically.")
                            .font(.system(size: 12))
                            .foregroundColor(C.dim)

                        TextEditor(text: $bugDesc)
                            .font(.system(size: 13))
                            .foregroundColor(C.text)
                            .frame(minHeight: 90, maxHeight: 140)
                            .padding(6)
                            .background(C.surf)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        HStack(spacing: 16) {
                            if isSending {
                                ProgressView().scaleEffect(0.7)
                                Text("Sending…")
                                    .font(.system(size: 13))
                                    .foregroundColor(C.dim)
                            } else {
                                RimeoButton(title: "Send Report", icon: "ladybug", color: C.acc, action: sendBugReport)
                            }

                            if !bugStatus.isEmpty {
                                Text(bugStatus)
                                    .font(.system(size: 13))
                                    .foregroundColor(bugStatus.hasPrefix("✓") ? C.green : C.red)
                            }
                        }
                    }
                    .padding(20)
                }

                HStack(spacing: 8) {
                    SectionLabel(text: "LOG OUTPUT")
                    Spacer()
                    compactActionButton(title: "Copy", icon: "doc.on.doc", action: copyLogs)
                    compactActionButton(title: "Refresh", icon: "arrow.clockwise", action: refreshLogs)
                }

                ScrollView {
                    Text(logText.isEmpty ? "(no log entries yet)" : logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "#8b949e"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(minHeight: 320)
                .background(Color(hex: "#0d1117"))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(C.brd, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(C.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshLogs() }
    }

    @ViewBuilder
    private func compactActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(C.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(C.surf)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.brd, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func refreshLogs() {
        logText = logger.lastLines(200)
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
        bugStatus = "✓ Copied to clipboard"
    }

    private func sendBugReport() {
        let desc = bugDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desc.isEmpty else {
            bugStatus = "Please describe the issue."
            return
        }

        isSending = true
        bugStatus = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let payload = try? JSONSerialization.data(withJSONObject: ["description": desc])
            let resp = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: "/api/report_bug",
                queryParams: [:],
                headers: [:],
                body: payload ?? Data()
            ))

            DispatchQueue.main.async {
                isSending = false
                if resp.status == 200 {
                    bugStatus = "✓ Bug report sent!"
                    bugDesc = ""
                } else {
                    let msg = extractDetail(resp) ?? "Error \(resp.status)"
                    bugStatus = "Error: \(msg)"
                }
            }
        }
    }

    private func extractDetail(_ resp: HTTPResponse) -> String? {
        guard case .data(let data) = resp.body,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["detail"] as? String
    }
}
