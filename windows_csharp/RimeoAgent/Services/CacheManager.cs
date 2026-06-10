using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

/// <summary>
/// Enforces the user-configured cache size limit (DataStore.MaxCacheGb).
/// The cache directory holds converted WAVs, waveform JSON and artwork. Nothing
/// used to trim it, so it could grow past the configured limit. CacheManager
/// prunes the directory down to the limit, deleting least-recently-used files first.
/// 1:1 mirror of the macOS agent's CacheManager.swift.
/// </summary>
public sealed class CacheManager
{
    public static readonly CacheManager Shared = new();

    private readonly object _lock = new();
    private bool _scheduled;

    private CacheManager() { }

    /// <summary>Schedules a prune on a background thread, coalescing rapid calls.</summary>
    public void ScheduleEnforce()
    {
        lock (_lock) { if (_scheduled) return; _scheduled = true; }
        Task.Run(() =>
        {
            lock (_lock) { _scheduled = false; }
            EnforceLimit();
        });
    }

    /// <summary>
    /// Synchronously prunes the cache down to the configured max, removing the
    /// least-recently-used files first. No-op when already under the limit.
    /// </summary>
    public void EnforceLimit()
    {
        try
        {
            var maxGb = DataStore.Shared.Data.MaxCacheGb;
            if (maxGb <= 0) return;
            long limit = (long)(maxGb * 1_073_741_824.0);

            var dir = AppConfig.Shared.CacheDir;
            if (!Directory.Exists(dir)) return;

            var files = new DirectoryInfo(dir).GetFiles("*", SearchOption.AllDirectories);
            long total = files.Sum(f => f.Length);
            if (total <= limit) return;

            foreach (var f in files.OrderBy(f => f.LastAccessTimeUtc))
            {
                if (total <= limit) break;
                try { var len = f.Length; f.Delete(); total -= len; } catch { }
            }
            Log.Info($"Cache prune: now {total / 1_048_576} MB, limit {limit / 1_048_576} MB");
        }
        catch (Exception ex)
        {
            Log.Error($"Cache prune failed: {ex.Message}");
        }
    }
}
