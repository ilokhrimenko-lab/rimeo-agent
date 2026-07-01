import SwiftUI
import AppKit

// NOTE: SourceKit may flag `C` / `AppState` / `HTTPRequest` as "not in scope"
// when indexing this file alone — false positive; all live in the same
// RimeoAgentMac module and resolve at `swift build` time.
//
// First-run auth gate. Until the agent is signed in to a Rimeo account
// (cloud_url present), this is the only screen available. Ported from the
// "Agent — Sign In / Create Account" Paper redesign. Colors come from the
// adaptive `C` palette, so this single view renders in both light and dark.
struct LinkDeviceView: View {
    @EnvironmentObject var appState: AppState

    private enum Mode { case signIn, createAccount }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isBusy = false
    @State private var statusMsg = ""
    @FocusState private var emailFocused: Bool

    private let formWidth: CGFloat = 374

    var body: some View {
        ZStack(alignment: .top) {
            C.bg.ignoresSafeArea()

            // Centered wordmark; the native window draws the traffic lights.
            HStack(spacing: 7) {
                Text("Rimeo").font(.system(size: 13, weight: .bold)).foregroundColor(C.body)
                Text("Agent").font(.system(size: 13, weight: .medium)).foregroundColor(C.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)

            gate.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { emailFocused = true }
    }

    // MARK: - Gate column

    private var gate: some View {
        VStack(spacing: 0) {
            emblem

            Text(mode == .signIn ? "Sign in to Rimeo" : "Create your account")
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(C.text)
                .padding(.top, 22)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(C.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360)
                .padding(.top, 9)

            VStack(spacing: 16) {
                emailField
                passwordField
                primaryButton.padding(.top, 6)
                footerLink
                if mode == .signIn { sessionNote }
            }
            .frame(width: formWidth)
            .padding(.top, 28)

            if !statusMsg.isEmpty {
                Text(statusMsg)
                    .font(.system(size: 13))
                    .foregroundColor(C.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: formWidth)
                    .padding(.top, 14)
            }
        }
        .frame(width: 430)
    }

    private var subtitle: String {
        mode == .signIn
            ? "Use your Rimeo account to connect this agent. Your library stays in sync everywhere you listen."
            : "Set up a Rimeo account to sync your library everywhere you listen."
    }

    private var emblem: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous).fill(C.accSoft)
            Image(systemName: mode == .signIn ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .font(.system(size: 25, weight: .semibold))
                .foregroundColor(C.accText)
        }
        .frame(width: 60, height: 60)
    }

    // MARK: - Fields

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Email")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(C.secondary)
            HStack(spacing: 10) {
                Image(systemName: "envelope").font(.system(size: 14)).foregroundColor(C.dim)
                TextField("you@email.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(C.text)
                    .focused($emailFocused)
                    .onSubmit(doSubmit)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(C.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(C.brd, lineWidth: 1))
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Password")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.secondary)
                Spacer()
                if mode == .signIn {
                    Button(action: openForgot) {
                        Text("Forgot password?")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(C.accText)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Use 8+ characters")
                        .font(.system(size: 13))
                        .foregroundColor(C.dim)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "lock").font(.system(size: 14)).foregroundColor(C.dim)
                Group {
                    if showPassword {
                        TextField(passwordPlaceholder, text: $password)
                    } else {
                        SecureField(passwordPlaceholder, text: $password)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(C.text)
                .onSubmit(doSubmit)
                Button(action: { showPassword.toggle() }) {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 14)).foregroundColor(C.dim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(C.field)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(C.brd, lineWidth: 1))
        }
    }

    private var passwordPlaceholder: String {
        mode == .signIn ? "Your password" : "Create a password"
    }

    // MARK: - Actions

    private var primaryButton: some View {
        Button(action: doSubmit) {
            HStack(spacing: 9) {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(buttonTitle).font(.system(size: 15, weight: .semibold))
                if !isBusy {
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(C.acc)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: C.acc.opacity(0.25), radius: 8, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var buttonTitle: String {
        if isBusy { return mode == .signIn ? "Signing in…" : "Creating…" }
        return mode == .signIn ? "Sign in" : "Create account"
    }

    private var footerLink: some View {
        HStack(spacing: 5) {
            Text(mode == .signIn ? "New to Rimeo?" : "Already have an account?")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(C.secondary)
            Button(action: toggleMode) {
                Text(mode == .signIn ? "Create account" : "Sign in")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(C.accText)
            }
            .buttonStyle(.plain)
        }
    }

    private var sessionNote: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundColor(C.dim)
            Text("One agent per account — signing in here signs out any other.")
                .font(.system(size: 13))
                .foregroundColor(C.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .frame(width: formWidth, alignment: .leading)
        .background(C.surf)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(C.cardBrd, lineWidth: 1))
    }

    private func toggleMode() {
        mode = (mode == .signIn) ? .createAccount : .signIn
        statusMsg = ""
    }

    private func openForgot() {
        if let url = URL(string: "\(AppConfig.shared.rimeoAppURL)/forgot-password") {
            NSWorkspace.shared.open(url)
        }
    }

    private func doSubmit() {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mail.contains("@"), !password.isEmpty else {
            statusMsg = "Enter your email and password."
            return
        }
        if mode == .createAccount, password.count < 8 {
            statusMsg = "Password must be at least 8 characters."
            return
        }

        isBusy = true
        statusMsg = ""
        let path = mode == .signIn ? "/api/agent_login" : "/api/agent_signup"
        let isSignIn = mode == .signIn

        DispatchQueue.global(qos: .userInitiated).async {
            let payload = try? JSONSerialization.data(withJSONObject: [
                "email": mail,
                "password": password,
            ])
            let resp = APIRouter.shared.route(HTTPRequest(
                method: "POST",
                path: path,
                queryParams: [:],
                headers: [:],
                body: payload ?? Data(),
                trusted: true   // in-process UI call — not socket traffic
            ))

            DispatchQueue.main.async {
                isBusy = false
                if resp.status == 200 {
                    // cloud_url is now set in DataStore; refresh flips cloudLinked
                    // → ContentView swaps this gate for the rest of the app.
                    appState.refreshFromData()
                } else {
                    let detail = (try? JSONSerialization.jsonObject(with: bodyData(resp)) as? [String: Any])?["detail"] as? String
                    statusMsg = detail ?? (isSignIn
                        ? "Sign-in failed. Check your email and password."
                        : "Could not create the account.")
                }
            }
        }
    }

    private func bodyData(_ resp: HTTPResponse) -> Data {
        if case .data(let data) = resp.body { return data }
        return Data()
    }
}
