import Foundation

/// Enforces the user-configured cache size limit (`DataStore.max_cache_gb`).
///
/// The cache directory holds converted WAVs, waveform JSON and artwork. Nothing
/// used to trim it, so it could grow past the configured limit indefinitely.
/// `CacheManager` prunes the directory down to the limit by deleting the
/// least-recently-used files first.
final class CacheManager {
    static let shared = CacheManager()

    private let queue = DispatchQueue(label: "rimeo.cache.prune", qos: .utility)
    private let scheduleLock = NSLock()
    private var pruneScheduled = false

    private init() {}

    /// Schedules a prune on a background queue, coalescing rapid successive
    /// calls (e.g. a burst of cache writes) into a single pass.
    func scheduleEnforce() {
        scheduleLock.lock()
        if pruneScheduled { scheduleLock.unlock(); return }
        pruneScheduled = true
        scheduleLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.scheduleLock.lock()
            self.pruneScheduled = false
            self.scheduleLock.unlock()
            self.enforceLimit()
        }
    }

    /// Synchronously prunes the cache directory down to the configured max,
    /// removing least-recently-used files first. No-op when already under limit
    /// or when the limit is unset.
    func enforceLimit() {
        let maxGB = DataStore.shared.data.max_cache_gb
        guard maxGB > 0 else { return }
        let limit = Int64(maxGB * 1_073_741_824)

        let dir = AppConfig.shared.cacheDir
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey, .isRegularFileKey,
        ]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        struct Entry { let url: URL; let size: Int64; let date: Date }
        var entries: [Entry] = []
        var total: Int64 = 0

        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: keys),
                  vals.isRegularFile == true else { continue }
            let size = Int64(vals.fileSize ?? 0)
            let date = vals.contentAccessDate ?? vals.contentModificationDate ?? .distantPast
            total += size
            entries.append(Entry(url: url, size: size, date: date))
        }

        guard total > limit else { return }

        // Oldest (least-recently-used) first.
        entries.sort { $0.date < $1.date }
        var remaining = total
        var freed: Int64 = 0
        for entry in entries {
            if remaining <= limit { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                remaining -= entry.size
                freed += entry.size
            }
        }

        logger.info("Cache prune: removed \(freed / 1_048_576) MB, was \(total / 1_048_576) MB, limit \(limit / 1_048_576) MB")
    }
}
