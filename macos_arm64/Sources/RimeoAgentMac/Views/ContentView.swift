import SwiftUI
import Combine

// Palette matching Python Flet UI
let C = ColorPalette.self

enum ColorPalette {
    static let bg    = Color(hex: "#0b1120")
    static let surf  = Color(hex: "#151c2c")
    static let acc   = Color(hex: "#3b82f6")
    static let text  = Color(hex: "#f1f3f4")
    static let brd   = Color(hex: "#1e293b")
    static let dim   = Color(hex: "#64748b")
    static let green = Color(hex: "#4ade80")
    static let red   = Color(hex: "#f87171")
    static let amber = Color(hex: "#f59e0b")
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.componentGateState {
            case .clear:
                if appState.isOnboarding {
                    OnboardingView()
                } else {
                    MainLayout()
                        .sheet(isPresented: $appState.showDiskAccessBanner) {
                            DiskAccessBannerView()
                        }
                }
            default:
                ComponentGateView()
            }
        }
        .onAppear {
            appState.refreshDiskAccessBannerState()
        }
    }
}

struct MainLayout: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            RailSidebarView()
                .frame(width: 90)

            Rectangle()
                .fill(C.brd)
                .frame(width: 1)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 36)
                .padding(.trailing, 36)
                .padding(.top, 32)
                .padding(.bottom, 24)
        }
        .background(C.bg)
        .preferredColorScheme(.dark)
        .padding(.top, 8)
        .overlay(
            VStack {
                Spacer()
                if appState.tunnelRateLimited {
                    TunnelRateLimitBanner()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.tunnelRateLimited)
        )
    }

    @ViewBuilder
    var tabContent: some View {
        switch appState.selectedTab {
        case 0:  LibraryTabView()
        case 1:  AnalysisTabView()
        case 2:  PairingTabView()
        case 3:  AccountTabView()
        case 4:  LogsTabView()
        default: LibraryTabView()
        }
    }
}

struct RailSidebarView: View {
    @EnvironmentObject var appState: AppState

    private let items: [(String, String, Int)] = [
        ("folder",    "Library",  0),
        ("waveform",  "Analysis", 1),
        ("qrcode",    "Pairing",  2),
        ("cloud",     "Account",  3),
        ("gearshape", "Settings", 4),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items, id: \.2) { (icon, label, idx) in
                RailItem(icon: icon, label: label, isSelected: appState.selectedTab == idx) {
                    appState.selectedTab = idx
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.surf)
    }
}

struct RailItem: View {
    let icon:       String
    let label:      String
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? C.acc : C.dim)
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? C.text : C.dim)
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(isSelected ? C.acc.opacity(0.12) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.clear, lineWidth: 0)
        )
    }
}

// MARK: - Shared Components

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(C.dim)
            .padding(.top, 4)
    }
}

struct SurfaceCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surf)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.brd, lineWidth: 1))
    }
}

struct StatusBadge: View {
    let isOk:  Bool
    let text:  String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isOk ? "checkmark.circle" : "xmark.circle")
                .foregroundColor(isOk ? C.green : C.red)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(isOk ? C.green : C.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isOk ? C.green.opacity(0.1) : C.red.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isOk ? C.green.opacity(0.4) : C.red.opacity(0.4), lineWidth: 1)
        )
    }
}

struct StepRow: View {
    let number: String
    let text:   String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(C.acc)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(C.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}

struct RimeoButton: View {
    let title:  String
    let icon:   String?
    let color:  Color
    let action: () -> Void
    var isDestructive = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 13)) }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(isDestructive ? C.red : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

struct TunnelRateLimitBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(C.amber)
                .font(.system(size: 13))
            Text("Too many tunnel connection attempts. Retrying in \(appState.tunnelRetryIn).")
                .font(.system(size: 12))
                .foregroundColor(C.text)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(C.amber.opacity(0.12))
        .overlay(Rectangle().frame(height: 1).foregroundColor(C.amber.opacity(0.35)), alignment: .top)
    }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8)  & 0xFF) / 255
        let b = Double( v        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
