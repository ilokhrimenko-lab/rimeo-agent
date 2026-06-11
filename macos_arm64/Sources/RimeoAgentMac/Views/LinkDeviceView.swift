import SwiftUI
import AppKit

// NOTE: SourceKit may flag `C` / `AppState` as "not in scope" when indexing this
// file alone — false positive; both live in the same RimeoAgentMac module and
// resolve at `swift build` time (same as OnboardingView etc.).
// First-run pairing gate. Until the agent is linked to a Rimeo account
// (cloud_url present), this is the only screen available — matching the
// "Agent — Link Device" Paper redesign. Colors come from the adaptive `C`
// palette, so this single view renders correctly in both light and dark.
struct LinkDeviceView: View {
    @EnvironmentObject var appState: AppState

    @State private var code      = ""
    @State private var statusMsg = ""
    @State private var isLinking = false
    @FocusState private var fieldFocused: Bool

    private let codeLength: Int = 8
    private let fieldWidth: CGFloat = 408

    var body: some View {
        ZStack(alignment: .top) {
            C.bg.ignoresSafeArea()

            // Titlebar wordmark (traffic lights are drawn by the native window,
            // top-left; a centered wordmark never collides with them).
            HStack(spacing: 7) {
                Text("Rimeo")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(C.body)
                Text("Agent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)

            gate
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Gate column

    private var gate: some View {
        VStack(spacing: 0) {
            emblem

            Text("Let's pair your device")
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(C.text)
                .padding(.top, 22)

            Text("Start by linking this agent to your Rimeo account. Enter the pairing code from rimeo.app to set up the pair.")
                .font(.system(size: 14))
                .foregroundColor(C.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360)
                .padding(.top, 9)

            codeField
                .padding(.top, 26)

            linkButton
                .padding(.top, 22)

            pasteButton
                .padding(.top, 14)

            if !statusMsg.isEmpty {
                Text(statusMsg)
                    .font(.system(size: 13))
                    .foregroundColor(C.red)
                    .padding(.top, 12)
            }

            hint
                .padding(.top, 22)
        }
        .frame(width: 430)
    }

    private var emblem: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(C.accSoft)
            Image(systemName: "link")
                .font(.system(size: 25, weight: .semibold))
                .foregroundColor(C.accText)
        }
        .frame(width: 60, height: 60)
    }

    // MARK: - Segmented code field

    private var codeField: some View {
        ZStack {
            // Invisible field captures keystrokes; the cells are the visuals.
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: code) { _ in
                    let cleaned = code.uppercased().filter { $0.isLetter || $0.isNumber }
                    code = String(cleaned.prefix(codeLength))
                }
                .onSubmit(doLink)

            HStack(spacing: 8) {
                ForEach(0..<codeLength, id: \.self) { index in
                    cell(index: index)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { fieldFocused = true }
        }
        .onAppear { fieldFocused = true }
    }

    private func cell(index: Int) -> some View {
        let chars = Array(code)
        let char = index < chars.count ? String(chars[index]) : ""
        let isActive = fieldFocused && index == chars.count

        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(C.surf)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive ? C.acc : C.brd, lineWidth: isActive ? 2 : 1)
                )
                .shadow(color: isActive ? C.acc.opacity(0.22) : .clear, radius: 4)

            if !char.isEmpty {
                Text(char)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(C.text)
            } else if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(C.acc)
                    .frame(width: 2, height: 24)
            }
        }
        .frame(width: 44, height: 56)
    }

    // MARK: - Actions

    private var linkButton: some View {
        Button(action: doLink) {
            HStack(spacing: 9) {
                if isLinking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "link").font(.system(size: 15, weight: .semibold))
                }
                Text(isLinking ? "Linking…" : "Link device")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(C.acc)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: C.acc.opacity(0.25), radius: 8, y: 6)
        }
        .buttonStyle(.plain)
        .frame(width: fieldWidth)
        .disabled(isLinking)
    }

    private var pasteButton: some View {
        Button(action: pasteCode) {
            HStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 12))
                Text("Paste from clipboard").font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(C.secondary)
        }
        .buttonStyle(.plain)
    }

    private var hint: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundColor(C.dim)
            (Text("Find your code at ").foregroundColor(C.secondary)
             + Text("rimeo.app › Account › Link Token").foregroundColor(C.accText).fontWeight(.semibold))
                .font(.system(size: 13))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(C.surf)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(C.cardBrd, lineWidth: 1))
    }

    private func doLink() {
        let token = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count == codeLength else {
            statusMsg = "Enter the \(codeLength)-character code."
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
                    // cloud_url is now set in DataStore; refresh flips cloudLinked
                    // → ContentView swaps this gate for the rest of the app.
                    appState.refreshFromData()
                } else {
                    let detail = (try? JSONSerialization.jsonObject(with: bodyData(resp)) as? [String: Any])?["detail"] as? String
                    statusMsg = detail ?? "Invalid or expired code. Generate a new one on rimeo.app."
                }
            }
        }
    }

    private func pasteCode() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        let cleaned = s.uppercased().filter { $0.isLetter || $0.isNumber }
        code = String(cleaned.prefix(codeLength))
        fieldFocused = true
    }

    private func bodyData(_ resp: HTTPResponse) -> Data {
        if case .data(let data) = resp.body { return data }
        return Data()
    }
}
