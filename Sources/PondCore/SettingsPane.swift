import Foundation

/// Picks the System Settings page for screen savers from the panes a Mac actually has.
/// The page's identifier changes between macOS releases, so it is looked up at run time
/// (the app lists /System/Library/ExtensionKit/Extensions) instead of hard-coded.
public enum SettingsPane {
    public struct Candidate: Equatable, Sendable {
        public var identifier: String
        public var name: String
        public init(identifier: String, name: String) { self.identifier = identifier; self.name = name }
    }

    /// Best match for the screen-saver page, or nil if the Mac has nothing like it.
    /// Preference: identifier mentions the screen saver → name says so → the wallpaper page (screen savers
    /// have lived under it on some releases).
    public static func screenSaver(in candidates: [Candidate]) -> Candidate? {
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") }
        func score(_ c: Candidate) -> Int {
            let id = norm(c.identifier), name = norm(c.name)
            if id.contains("screensaver") { return id.hasSuffix("settings.extension") || id.contains("settings") ? 100 : 90 }
            if name.contains("screensaver") || c.name.contains("屏幕保护") { return 80 }
            if id.contains("wallpaper") { return id.contains("settings") ? 40 : 30 }
            if name.contains("wallpaper") || c.name.contains("墙纸") || c.name.contains("壁纸") { return 20 }
            return 0
        }
        let ranked = candidates.map { ($0, score($0)) }.filter { $0.1 > 0 }
        return ranked.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.identifier > b.0.identifier }?.0
    }

    public static func url(for c: Candidate) -> URL? { URL(string: "x-apple.systempreferences:\(c.identifier)") }
}
