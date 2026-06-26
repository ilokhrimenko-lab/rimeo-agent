import SwiftUI

struct AccountTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ScreenHeader(title: "Account",
                             subtitle: "You're signed in to Rimeo. Devices on the same account connect automatically.")

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
                    SectionLabel(text: "ACTIVE SESSION")
                    SurfaceCard {
                        sessionRow.padding(20)
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

    private var sessionRow: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(C.accSoft)
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(C.accText)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("This computer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(C.text)
                Text("One agent stays active per account — signing in on another computer signs this one out.")
                    .font(.system(size: 13))
                    .foregroundColor(C.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func doSignOut() {
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
}
