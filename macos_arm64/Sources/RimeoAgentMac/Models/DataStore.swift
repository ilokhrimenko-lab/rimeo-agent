import Foundation

// Persistent data stored in rimo_data.json
struct RimoData: Codable {
    var notes:             [String: String]    = [:]
    // Custom display names for Rekordbox play-history sessions (djmdHistory.ID →
    // user-chosen name). Rekordbox's own DB is read-only to us, so renames live
    // here and are applied to the parsed library on every read. Synced to all
    // clients (iOS + web) because both read names from this agent.
    var history_names:     [String: String]    = [:]
    var global_exclusions: [String]            = []
    var pairing_code:      String              = ""
    // Per-device LAN pre-shared key (M4). Strong, persistent (unlike the rotating
    // 5-char pairing_code). Authorises direct local-network requests without a
    // server JWT; emitted in the v2 QR as `secret` and sent back as `?lan_token=`.
    var lan_secret:        String              = ""
    var cloud_url:         String              = ""
    var cloud_user_id:     String?             = nil
    var cloud_token:       String              = ""
    var tunnel_url:        String              = ""
    var max_cache_gb:      Double              = 3.0
    var just_updated:      Bool               = false
    var pending_update_url: String            = ""
    var pending_update_tag: String            = ""
    // Silent auto-update: hourly check downloads the new build's zip to a staging
    // file in the background; it is applied (extract+replace+relaunch) on the next
    // launch. `staged_update_tag` non-empty = a staged build is ready to install.
    var staged_update_tag: String             = ""
}

// Resilient decoding. The synthesized `Codable.init(from:)` calls `decode` (not
// `decodeIfPresent`) for every non-optional field and IGNORES the struct's
// default values — so an older `rimo_data.json` that predates a newly-added
// field would throw `keyNotFound`, get swallowed by `load()`'s `try?`, and reset
// the whole store to empty → the agent would silently unpair on every update
// that introduced a field. Decoding each key with `decodeIfPresent ?? default`
// makes schema evolution forward/backward compatible. (Defined in an extension
// so the memberwise `init()` used by `RimoData()` stays synthesized.)
extension RimoData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        notes              = try c.decodeIfPresent([String: String].self, forKey: .notes)             ?? notes
        history_names      = try c.decodeIfPresent([String: String].self, forKey: .history_names)     ?? history_names
        global_exclusions  = try c.decodeIfPresent([String].self,         forKey: .global_exclusions) ?? global_exclusions
        pairing_code       = try c.decodeIfPresent(String.self,           forKey: .pairing_code)      ?? pairing_code
        lan_secret         = try c.decodeIfPresent(String.self,           forKey: .lan_secret)        ?? lan_secret
        cloud_url          = try c.decodeIfPresent(String.self,           forKey: .cloud_url)         ?? cloud_url
        cloud_user_id      = try c.decodeIfPresent(String.self,           forKey: .cloud_user_id)     ?? cloud_user_id
        cloud_token        = try c.decodeIfPresent(String.self,           forKey: .cloud_token)       ?? cloud_token
        tunnel_url         = try c.decodeIfPresent(String.self,           forKey: .tunnel_url)        ?? tunnel_url
        max_cache_gb       = try c.decodeIfPresent(Double.self,           forKey: .max_cache_gb)      ?? max_cache_gb
        just_updated       = try c.decodeIfPresent(Bool.self,             forKey: .just_updated)      ?? just_updated
        pending_update_url = try c.decodeIfPresent(String.self,           forKey: .pending_update_url) ?? pending_update_url
        pending_update_tag = try c.decodeIfPresent(String.self,           forKey: .pending_update_tag) ?? pending_update_tag
        staged_update_tag  = try c.decodeIfPresent(String.self,           forKey: .staged_update_tag) ?? staged_update_tag
    }
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
                // Atomic: a crash/shutdown mid-write must not leave a truncated
                // JSON that fails to decode and resets the store (→ unpair).
                try? raw.write(to: AppConfig.shared.dataFile, options: .atomic)
            }
        }
    }

    func update(_ block: (inout RimoData) -> Void) {
        var copy = data
        block(&copy)
        save(copy)
    }
}
