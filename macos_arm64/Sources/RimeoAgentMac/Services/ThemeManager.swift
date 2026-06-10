import AppKit

/// User-selectable app appearance.
enum AppTheme: String, CaseIterable {
    case auto   // follow macOS system appearance
    case light
    case dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }
}

/// Persists the chosen theme and applies it app-wide via `NSApp.appearance`.
///
/// Applying the appearance *before* the main window is created means the very
/// first frame already renders in the correct theme — no dark flash before a
/// stored preference is read.
final class ThemeManager {
    static let shared = ThemeManager()

    private let key = "rimeo_settings_theme"
    private let defaults = UserDefaults.standard
    private init() {}

    var theme: AppTheme {
        AppTheme(rawValue: defaults.string(forKey: key) ?? "") ?? .auto
    }

    func setTheme(_ theme: AppTheme) {
        defaults.set(theme.rawValue, forKey: key)
        apply()
    }

    /// Applies the stored theme to the whole application. Safe to call repeatedly.
    func apply() {
        NSApp.appearance = theme.nsAppearance
    }
}
