import Foundation
import Combine

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var xmlPath:        String  = AppConfig.shared.xmlPath
    @Published var isOnboarding:   Bool    = false
    @Published var selectedTab:    Int     = 0
    @Published var componentGateState: ComponentGateState = .checking

    // Analysis progress
    @Published var analysisRunning:   Bool   = false
    @Published var analysisDone:      Int    = 0
    @Published var analysisTotal:     Int    = 0
    @Published var analysisCurrent:   String = ""
    @Published var analysisErrors:    Int    = 0
    @Published var analysisUnavailable: Int  = 0

    // Tunnel
    @Published var tunnelActive:      Bool   = false
    @Published var tunnelURL:         String = ""
    @Published var tunnelRateLimited: Bool   = false
    @Published var tunnelRetryIn:     String = ""
    private var rateLimitTimer: Timer?

    // Cloud link status (mirrored for UI)
    @Published var cloudLinked:  Bool   = false
    @Published var cloudEmail:   String = ""

    // Full Disk Access banner
    @Published var showDiskAccessBanner:   Bool = false
    @Published var fdaResetAfterUpdate:    Bool = false

    private static let fdaDismissedKey = "rimeo_fda_banner_dismissed"

    private init() {
        let cfg = AppConfig.shared
        isOnboarding = !cfg.hasAnyLibrarySource

        let d = DataStore.shared.data
        cloudLinked  = !d.cloud_url.isEmpty
        cloudEmail   = d.cloud_user_id ?? ""
        tunnelURL    = d.tunnel_url
        tunnelActive = !d.tunnel_url.isEmpty

        checkFdaAfterUpdate()
        refreshDiskAccessBannerState()
    }

    private func checkFdaAfterUpdate() {
        guard DataStore.shared.data.just_updated else { return }
        DataStore.shared.update { $0.just_updated = false }
        guard !AppState.hasFullDiskAccess() else { return }
        UserDefaults.standard.removeObject(forKey: AppState.fdaDismissedKey)
        fdaResetAfterUpdate = true
    }

    func dismissDiskAccessBanner() {
        UserDefaults.standard.set(true, forKey: AppState.fdaDismissedKey)
        showDiskAccessBanner = false
    }

    func refreshDiskAccessBannerState() {
        let hasAccess = AppState.hasFullDiskAccess()
        let dismissed = UserDefaults.standard.bool(forKey: AppState.fdaDismissedKey)

        DispatchQueue.main.async {
            self.showDiskAccessBanner = hasAccess ? false : !dismissed
        }
    }

    static func hasFullDiskAccess() -> Bool {
        TCCDiagnostics.hasFullDiskAccess()
    }

    func refreshFromData() {
        let d = DataStore.shared.data
        DispatchQueue.main.async {
            self.cloudLinked  = !d.cloud_url.isEmpty
            self.cloudEmail   = d.cloud_user_id ?? ""
            self.tunnelURL    = d.tunnel_url
        }
    }

    func finishOnboarding(xmlPath: String) {
        AppConfig.shared.setXMLPath(xmlPath)
        RekordboxParser.shared.invalidateCache()
        DispatchQueue.main.async {
            self.xmlPath     = xmlPath
            self.isOnboarding = false
        }
    }

    func finishOnboarding(dbPath: String) {
        AppConfig.shared.setDBPath(dbPath)
        RekordboxParser.shared.invalidateCache()
        DispatchQueue.main.async {
            self.isOnboarding = false
        }
    }

    func setTunnelRateLimited(delay: TimeInterval = 15 * 60) {
        let until = Date().addingTimeInterval(delay)
        DispatchQueue.main.async {
            self.tunnelRateLimited = true
            self.updateRetryIn(until: until)
            self.rateLimitTimer?.invalidate()
            self.rateLimitTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                if Date() >= until {
                    self.tunnelRateLimited = false
                    self.tunnelRetryIn = ""
                    t.invalidate()
                } else {
                    self.updateRetryIn(until: until)
                }
            }
        }
    }

    private func updateRetryIn(until: Date) {
        let mins = Int(max(0, until.timeIntervalSinceNow) / 60) + 1
        tunnelRetryIn = "\(mins) min"
    }

    func refreshLibrarySource() {
        DispatchQueue.main.async {
            self.xmlPath = AppConfig.shared.xmlPath
            self.isOnboarding = !AppConfig.shared.hasAnyLibrarySource
        }
    }
}
