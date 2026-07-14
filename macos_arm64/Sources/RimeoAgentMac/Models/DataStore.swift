import Foundation
import CryptoKit

// Overlay record for a user-editable playlist (Фаза 0 — плейлисты из iOS). Lives
// in rimo_data.json next to notes/exclusions. `master.db` is never written in v1;
// these overlays are merged into /api/data at read time. A pure-Rimeo playlist has
// `rekordbox_id == nil` (synthetic path `rmo:<rimeo_id>`); an edited Rekordbox
// playlist carries the real `rekordbox_id` and `dirty == true` (overlay overrides
// the parsed membership by id, never by path — same-named playlists collide).
struct PlaylistOverlay: Codable {
    var rimeo_id:         String   = ""
    var rekordbox_id:     String?  = nil
    var name:             String   = ""
    var parent:           String?  = nil
    var is_folder:        Bool     = false
    var track_ids:        [String] = []
    var state:            String   = "pending"
    var dirty:            Bool     = true
    var content_hash:     String?  = nil
    var last_synced_hash: String?  = nil
    // Tombstone (full-CRUD delete). A deleted overlay hides the playlist from
    // /api/data: a pure-Rimeo one is simply not emitted; an edited Rekordbox one
    // is removed from the parsed list (master.db is still never written in v1).
    var deleted:          Bool     = false
}

// Resilient decode (finding-20): decode each key with `decodeIfPresent ?? default`
// so a rimo_data.json written before a field was added never throws keyNotFound
// (which load()'s `try?` would swallow → the whole store resets → agent unpairs).
// In an extension so the memberwise `init()` stays synthesized for construction.
extension PlaylistOverlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        rimeo_id         = try c.decodeIfPresent(String.self,   forKey: .rimeo_id)         ?? rimeo_id
        rekordbox_id     = try c.decodeIfPresent(String.self,   forKey: .rekordbox_id)     ?? rekordbox_id
        name             = try c.decodeIfPresent(String.self,   forKey: .name)             ?? name
        parent           = try c.decodeIfPresent(String.self,   forKey: .parent)           ?? parent
        is_folder        = try c.decodeIfPresent(Bool.self,     forKey: .is_folder)        ?? is_folder
        track_ids        = try c.decodeIfPresent([String].self, forKey: .track_ids)        ?? track_ids
        state            = try c.decodeIfPresent(String.self,   forKey: .state)            ?? state
        dirty            = try c.decodeIfPresent(Bool.self,     forKey: .dirty)            ?? dirty
        content_hash     = try c.decodeIfPresent(String.self,   forKey: .content_hash)     ?? content_hash
        last_synced_hash = try c.decodeIfPresent(String.self,   forKey: .last_synced_hash) ?? last_synced_hash
        deleted          = try c.decodeIfPresent(Bool.self,     forKey: .deleted)          ?? deleted
    }
}

// Cross-platform playlist content hash (finding-7/25). MUST stay byte-identical to
// the iOS / web / Windows implementations or overlays never self-clear: SHA-256,
// lowercase hex, of the ordered `track_ids` joined by "\n". Order is significant;
// ids are not case-normalized. Single source of truth for every mutation handler.
enum PlaylistHash {
    static func contentHash(_ trackIDs: [String]) -> String {
        let joined = trackIDs.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// Sync signature (Фаза 6). `content_hash` covers ONLY membership (SHA-256 of the
// ordered track_ids) — a rename, a move, a folder create or a delete leaves it
// byte-identical, so a content_hash-based pending check would silently declare
// those changes already-synced. The sync signature covers everything the writer
// can push into master.db: name, parent, folder-ness, tombstone AND membership.
// `last_synced_hash` stores the signature of the state that was actually written,
// so `last_synced_hash != syncSignature` is exactly "there is something to sync".
extension PlaylistOverlay {
    var syncSignature: String {
        let parts = [name,
                     parent ?? "",
                     is_folder ? "1" : "0",
                     deleted   ? "1" : "0",
                     track_ids.joined(separator: "\n")]
        // \u{1F} (unit separator) can't occur in a name/path/track id → no collision
        // between e.g. name="a", parent="b" and name="a\u{1F}b", parent="".
        return PlaylistHash.contentHash([parts.joined(separator: "\u{1F}")])
    }
}

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
    // Overlay-only playlist edits from iOS (Фаза 0). Merged into /api/data at read
    // time; never written back to Rekordbox's master.db in v1.
    var playlists:         [PlaylistOverlay]   = []
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
        playlists          = try c.decodeIfPresent([PlaylistOverlay].self, forKey: .playlists)        ?? playlists
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

    // Overlays that still differ from what was last written into master.db
    // (Фаза 6). Single source of truth for both the Sync engine and the
    // `pending_sync` counter in /api/data — they must never disagree, or the iOS
    // button offers a sync that turns into a no-op (or hides one that is needed).
    // A tombstone for a playlist that never reached the DB has nothing to delete
    // there, so it is not pending (it is dropped from the overlay list on its own).
    // `last_synced_hash == nil` ⇒ never synced ⇒ pending.
    func pendingSyncOverlays() -> [PlaylistOverlay] {
        data.playlists.filter { ov in
            if ov.deleted && (ov.rekordbox_id ?? "").isEmpty { return false }
            return ov.last_synced_hash != ov.syncSignature
        }
    }
}
