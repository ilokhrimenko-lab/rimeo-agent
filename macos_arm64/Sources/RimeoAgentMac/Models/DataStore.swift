import Foundation

// Persistent data stored in rimo_data.json
struct RimoData: Codable {
    var notes:             [String: String]    = [:]
    var global_exclusions: [String]            = []
    var pairing_code:      String              = ""
    var cloud_url:         String              = ""
    var cloud_user_id:     String?             = nil
    var cloud_token:       String              = ""
    var tunnel_url:        String              = ""
    var max_cache_gb:      Double              = 3.0
    var just_updated:      Bool               = false
}

final class DataStore {
    static let shared = DataStore()

    private let queue = DispatchQueue(label: "rimeo.datastore", qos: .utility)
    private var _data = RimoData()

    var data: RimoData {
        queue.sync { _data }
    }

    private init() {
        _data = load()
    }

    private func load() -> RimoData {
        guard let raw = try? Data(contentsOf: AppConfig.shared.dataFile),
              let decoded = try? JSONDecoder().decode(RimoData.self, from: raw)
        else { return RimoData() }
        return decoded
    }

    func save(_ data: RimoData) {
        queue.sync { _data = data }
        DispatchQueue.global(qos: .utility).async {
            if let raw = try? JSONEncoder().encode(data) {
                try? raw.write(to: AppConfig.shared.dataFile)
            }
        }
    }

    func update(_ block: (inout RimoData) -> Void) {
        var copy = data
        block(&copy)
        save(copy)
    }
}
