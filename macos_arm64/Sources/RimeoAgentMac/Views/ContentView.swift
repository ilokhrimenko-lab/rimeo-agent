import SwiftUI
import AppKit

// MARK: - Adaptive design tokens
//
// Ported 1:1 from the Paper redesign ("Redesign Rimeo Agent"). Every token is
// adaptive: it resolves to the light value in Aqua and the dark value in Dark
// Aqua, following the macOS system appearance automatically.

let C = ColorPalette.self

private extension NSColor {
    convenience init(rgb hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green:   CGFloat((hex >> 8)  & 0xFF) / 255,
                  blue:    CGFloat(hex & 0xFF) / 255,
                  alpha:   1)
    }
}

/// Adaptive color: `light` in Aqua, `darkHex` in Dark Aqua.
func dyn(_ light: UInt32, _ darkHex: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgb: isDark ? darkHex : light)
    })
}

enum ColorPalette {
    // Surfaces
    static let bg        = dyn(0xF5F6F8, 0x141519)   // page background
    static let sidebar   = dyn(0xF4F5F8, 0x1B1D23)   // sidebar surface
    static let surf      = dyn(0xFFFFFF, 0x1E2128)   // card surface
    // Accent
    static let acc       = dyn(0x2563EB, 0x3B82F6)   // primary blue
    static let accSoft   = dyn(0xEAF0FE, 0x1E2E4F)   // blue tint (active nav, step circle, icon bg)
    static let accText   = dyn(0x2563EB, 0x6BA1FF)   // accent text/icon
    // Text
    static let text      = dyn(0x0A0A0B, 0xF2F3F5)   // primary ink
    static let body      = dyn(0x2B3445, 0xC7CCD6)   // step / body text
    static let secondary = dyn(0x5C616B, 0xAEB4BE)   // secondary text
    static let dim       = dyn(0x9499A3, 0x8B919B)   // muted labels
    static let faint     = dyn(0xAEB2BA, 0x6B7079)   // faint / disabled text
    // Lines & fills
    static let brd       = dyn(0xE6E8EC, 0x2E323B)   // hairline border
    static let cardBrd   = dyn(0xECEEF1, 0x2E323B)   // card border
    static let field     = dyn(0xF3F4F6, 0x23262E)   // input fill
    static let chip      = dyn(0xEEF0F3, 0x2A2E37)   // chip / pill fill
    // Semantic
    static let green     = dyn(0x2FAE73, 0x34C77E)
    static let greenSoft = dyn(0xEBF7F0, 0x14271C)
    static let red       = dyn(0xE5484D, 0xFF5A60)
    static let redSoft   = dyn(0xFEF2F2, 0x2A1618)
    static let redBrd    = dyn(0xF7D4D5, 0x4A2326)
    static let amber     = dyn(0xF59E0B, 0xFBB540)
    // Secondary button
    static let btn2      = dyn(0xFFFFFF, 0x2A2F39)
    static let btn2Brd   = dyn(0xE1E4E9, 0x2E323B)
    static let btn2Txt   = dyn(0x2B3445, 0xE6E8EC)
    // Switch off track
    static let switchOff = dyn(0xD7DAE0, 0x3A3F49)
    // Segmented control
    static let segTrack  = dyn(0xEBEDF1, 0x23262E)
    static let segActive = dyn(0xFFFFFF, 0x363C46)
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.componentGateState {
            case .clear:
                if !appState.cloudLinked {
                    LinkDeviceView()
                } else if appState.isOnboarding {
                    OnboardingView()
                } else {
                    MainLayout()
                        .overlay(
                            Group {
                                if appState.showDiskAccessBanner {
                                    ZStack {
                                        Color.black.opacity(0.5)
                                            .edgesIgnoringSafeArea(.all)
                                        DiskAccessBannerView()
                                    }
                                }
                            }
                        )
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
            SidebarView()
                .frame(width: 212)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(C.bg)
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
        case 2:  PairingTabView()
        case 3:  AccountTabView()
        case 4:  LogsTabView()
        default: LibraryTabView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    private let items: [(icon: String, label: String, idx: Int)] = [
        ("folder",    "Library",  0),
        ("macbook.and.iphone", "Devices", 2),
        ("cloud",     "Account",  3),
        ("gearshape", "Settings", 4),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Leave room for the window traffic lights, then the wordmark.
            HStack(spacing: 10) {
                Text("R")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(C.acc)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: C.acc.opacity(0.32), radius: 6, y: 3)
                Text("Rimeo")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(C.text)
                Text("Agent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(C.dim)
                    .padding(.top, 3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 38)
            .padding(.bottom, 20)

            VStack(spacing: 3) {
                ForEach(items, id: \.idx) { item in
                    NavRow(icon: item.icon,
                           label: item.label,
                           isSelected: appState.selectedTab == item.idx) {
                        appState.selectedTab = item.idx
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Circle()
                    .fill(C.green)
                    .frame(width: 7, height: 7)
                Text("Agent online")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(C.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 11)
            .overlay(Rectangle().frame(height: 1).foregroundColor(C.brd), alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.sidebar)
        .overlay(Rectangle().frame(width: 1).foregroundColor(C.brd), alignment: .trailing)
    }
}

struct NavRow: View {
    let icon:       String
    let label:      String
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? C.accText : C.dim)
                    .frame(width: 19)
                Text(label)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? C.accText : C.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(isSelected ? C.accSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared building blocks

struct ScreenHeader: View {
    let title:    String
    let subtitle: String?
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(C.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundColor(C.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .kerning(0.9)
            .foregroundColor(C.dim)
            .padding(.top, 6)
    }
}

struct SurfaceCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surf)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(C.cardBrd, lineWidth: 1))
    }
}

struct StatusBadge: View {
    let isOk:  Bool
    let text:  String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isOk ? C.green : C.red)
                .font(.system(size: 14))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isOk ? C.green : C.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isOk ? C.greenSoft : C.redSoft)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct StepRow: View {
    let number: String
    let text:   String
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(C.accText)
                .frame(width: 25, height: 25)
                .background(C.accSoft)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(C.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Spacer(minLength: 0)
        }
    }
}

/// Primary filled pill button (blue). Destructive variant renders red-on-soft-red.
struct RimeoButton: View {
    let title:  String
    let icon:   String?
    let color:  Color
    let action: () -> Void
    var isDestructive = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(isDestructive ? C.red : .white)
            .frame(height: 42)
            .padding(.horizontal, 20)
            .background(isDestructive ? C.redSoft : color)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isDestructive ? C.redBrd : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Outlined secondary pill button (surface fill, hairline border).
struct SecondaryButton: View {
    let title:  String
    let icon:   String?
    let action: () -> Void
    var destructive = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium))
                }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(destructive ? C.red : C.btn2Txt)
            .frame(height: 40)
            .padding(.horizontal, 16)
            .background(destructive ? C.redSoft : C.btn2)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(destructive ? C.redBrd : C.btn2Brd, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toggle styles

/// iOS-style sliding switch used for source enable/disable.
struct RimeoSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(configuration.isOn ? C.acc : C.switchOff)
                .frame(width: 46, height: 28)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .padding(3),
                    alignment: configuration.isOn ? .trailing : .leading
                )
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}

/// Rounded blue checkbox with a white check, used for agent settings.
struct RimeoCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isOn ? C.acc : Color.clear)
                    .frame(width: 21, height: 21)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(configuration.isOn ? Color.clear : C.brd, lineWidth: 1.5)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .opacity(configuration.isOn ? 1 : 0)
                    )
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - QR code

struct QRCodeView: View {
    let string: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image = QRCodeView.generate(string) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
            } else {
                C.field
            }
        }
        .frame(width: size, height: size)
    }

    static func generate(_ string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = 240 / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Banners

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

// MARK: - View helpers

extension View {
    /// Hides the default TextEditor/scroll background where supported (macOS 13+).
    @ViewBuilder func hideScrollBackground() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
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
