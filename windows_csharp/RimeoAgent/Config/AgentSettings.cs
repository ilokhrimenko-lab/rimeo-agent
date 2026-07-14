using Microsoft.Win32;
using RimeoAgent.Models;

namespace RimeoAgent.Config;

public static class AgentSettings
{
    private const string RunKey  = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "RimeoAgent";

    /// Аргумент, с которым агент поднимается из автозапуска: без окна, только трей.
    public const string BackgroundFlag = "--background";

    /// Текущий процесс поднят автозапуском (с BackgroundFlag). Ставится в App.OnLaunched
    /// и читается при перезапуске после обновления, чтобы не показать окно.
    public static bool LaunchedInBackground { get; internal set; }

    /// args — как из Environment.GetCommandLineArgs(): первый элемент = путь к exe.
    public static bool IsBackgroundCommandLine(IEnumerable<string> args) =>
        args.Skip(1).Any(a =>
            string.Equals(a, BackgroundFlag, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "-background",  StringComparison.OrdinalIgnoreCase) ||
            string.Equals(a, "/background",  StringComparison.OrdinalIgnoreCase));

    private static string RunCommand()
    {
        var exe = Environment.ProcessPath ?? "";
        return string.IsNullOrEmpty(exe) ? "" : $"\"{exe}\" {BackgroundFlag}";
    }

    public static bool LaunchAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(AppName) != null;
        }
        set
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null) return;
            if (value)
            {
                var cmd = RunCommand();
                if (!string.IsNullOrEmpty(cmd)) key.SetValue(AppName, cmd);
            }
            else
            {
                key.DeleteValue(AppName, throwOnMissingValue: false);
            }
        }
    }

    /// Автозапуск включаем сами — но ровно один раз, при первом запуске. Дальше решает
    /// пользователь (тумблер в Settings): если он выключил, повторно не включаем.
    public static void EnsureAutostartConfiguredOnce()
    {
        try
        {
            if (!DataStore.Shared.Data.AutostartConfigured)
            {
                LaunchAtLogin = true;
                DataStore.Shared.Update(d => d.AutostartConfigured = true);
                Log.Info("Autostart enabled automatically (first launch)");
                return;
            }

            // Самолечение: запись, сделанная старым билдом, не содержит --background
            // (тогда автостарт вылезал окном) или указывает на устаревший путь к exe.
            if (!LaunchAtLogin) return;
            var expected = RunCommand();
            if (string.IsNullOrEmpty(expected)) return;

            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key == null) return;
            if (key.GetValue(AppName) as string == expected) return;
            key.SetValue(AppName, expected);
            Log.Info("Autostart registry entry refreshed (background flag)");
        }
        catch (Exception ex) { Log.Warn($"Autostart setup failed: {ex.Message}"); }
    }
}
