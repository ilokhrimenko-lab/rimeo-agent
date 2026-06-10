using Microsoft.UI.Xaml;
using Microsoft.Win32;

namespace RimeoAgent.Config;

public enum AppTheme { Auto, Light, Dark }

/// <summary>
/// Persists the chosen appearance (Auto / Light / Dark) under HKCU\Software\RimeoAgent
/// and maps it to a WinUI <see cref="ElementTheme"/>. Mirror of the macOS ThemeManager.
/// </summary>
public static class ThemeManager
{
    private const string KeyPath   = @"Software\RimeoAgent";
    private const string ValueName = "Theme";

    public static AppTheme Theme
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            var s = key?.GetValue(ValueName) as string;
            return Enum.TryParse<AppTheme>(s, ignoreCase: true, out var t) ? t : AppTheme.Auto;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
            key?.SetValue(ValueName, value.ToString());
        }
    }

    public static ElementTheme ToElementTheme(AppTheme t) => t switch
    {
        AppTheme.Light => ElementTheme.Light,
        AppTheme.Dark  => ElementTheme.Dark,
        _              => ElementTheme.Default,
    };

    public static ElementTheme CurrentElementTheme => ToElementTheme(Theme);
}
