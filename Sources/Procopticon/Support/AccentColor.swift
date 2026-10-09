import AppKit

/// The app's own accent color: toolbar toggles, sidebar icons, selection highlights, switches and
/// everything else drawn in `controlAccentColor`.
///
/// AppKit has no public way to change it while running; its private
/// `-[NSApplication _setAccentColor:]` takes any color and updates `controlAccentColor` and the
/// selection colors derived from it at once. Being private, it's checked for first; without it the
/// setting does nothing. Like an app's Info.plist accent color, macOS uses it only while System
/// Settings' accent color is Multicolor.
enum AccentColor {
    private static let setter = Selector(("_setAccentColor:"))

    static var isSupported: Bool {
        NSApp.responds(to: setter)
    }

    /// nil goes back to the system's accent color. Windows redraw on their own: AppKit posts
    /// `NSColor.systemColorsDidChangeNotification`.
    static func apply(_ color: NSColor?) {
        guard isSupported else { return }
        NSApp.perform(setter, with: color)
    }

    /// True when System Settings has a specific accent color, which takes precedence over the app's.
    static var systemOverrides: Bool {
        CFPreferencesCopyValue("AppleAccentColor" as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) != nil
    }
}
