import Foundation
import Combine

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var xmlPath:        String  = AppConfig.shared.xmlPath
    @Published var isOnboarding:   Bool    = false
    @Published var selectedTab:    Int     = 0

    // Analysis progress
    @Published var analysisRunning:   Bool   = false
    @Published var analysisDone:      Int    = 0
    @Published var analysisTotal:     Int    = 0
    @Published var analysisCurrent:   String = ""
    @Published var analysisErrors:    Int    = 0
    @Published var analysisUnavailable: Int  = 0

    // Tunnel
    @Published var tunnelActive: Bool   = false
    @Published var tunnelURL:    String = ""

    // Cloud link status (mirrored for UI)
    @Published var cloudLinked:  Bool   = false
    @Published var cloudEmail:   String = ""

    // Full Disk Access banner
    @Published var showDiskAccessBanner: Bool = false

    private init() {
        let cfg = AppConfig.shared
        isOnboarding = !cfg.hasAnyLibrarySource

        let d = DataStore.shared.data
        cloudLinked  = !d.cloud_url.isEmpty
        cloudEmail   = d.cloud_user_id ?? ""
        tunnelURL    = d.tunnel_url
        tunnelActive = !d.tunnel_url.isEmpty

        showDiskAccessBanner = !AppState.hasFullDiskAccess()
    }

    static func hasFullDiskAccess() -> Bool {
        let tccDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: tccDB)
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

    func refreshLibrarySource() {
        DispatchQueue.main.async {
            self.xmlPath = AppConfig.shared.xmlPath
            self.isOnboarding = !AppConfig.shared.hasAnyLibrarySource
        }
    }
}
