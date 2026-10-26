import Foundation
import Combine
import PondCore

/// What the whole app shares: the pond configuration (saved to disk) and the display preferences.
final class AppState: ObservableObject {
    @Published var config: PondConfig
    @Published var windowMode: Bool { didSet { defaults.set(windowMode, forKey: Keys.window) } }
    @Published var wallpaperMode: Bool { didSet { defaults.set(wallpaperMode, forKey: Keys.wallpaper) } }
    @Published var wallpaperClickFeeds: Bool { didSet { defaults.set(wallpaperClickFeeds, forKey: Keys.wallpaperClicks) } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoUpdate) } }
    @Published var includePrereleases: Bool { didSet { defaults.set(includePrereleases, forKey: Keys.prerelease) } }
    @Published var lastSaveError: String?

    private let defaults = UserDefaults.standard
    private var saveWork: AnyCancellable?

    enum Keys {
        static let window = "windowMode", wallpaper = "wallpaperMode", wallpaperClicks = "wallpaperClickFeeds"
        static let autoUpdate = "autoCheckUpdates", prerelease = "includePrereleases"
        static let lastCheck = "lastUpdateCheck", skipped = "skippedVersion"
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("KoiPond", isDirectory: true)
    }
    static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }

    init() {
        defaults.register(defaults: [Keys.window: true, Keys.wallpaper: false, Keys.wallpaperClicks: true,
                                     Keys.autoUpdate: true, Keys.prerelease: false])
        windowMode = defaults.bool(forKey: Keys.window)
        wallpaperMode = defaults.bool(forKey: Keys.wallpaper)
        wallpaperClickFeeds = defaults.bool(forKey: Keys.wallpaperClicks)
        autoCheckUpdates = defaults.bool(forKey: Keys.autoUpdate)
        includePrereleases = defaults.bool(forKey: Keys.prerelease)
        if let data = try? Data(contentsOf: AppState.configURL), let c = try? PondConfig.decode(data) {
            config = c
        } else {
            config = Preset.koiPond.config
        }
        // save shortly after the last change
        saveWork = $config.dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] c in self?.save(c) }
        if !windowMode && !wallpaperMode { windowMode = true }
    }

    func save(_ c: PondConfig) {
        do {
            try FileManager.default.createDirectory(at: AppState.supportDirectory, withIntermediateDirectories: true)
            try c.encoded().write(to: AppState.configURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    func load(preset: Preset) { config = preset.config }

    func importConfig(from url: URL) throws { config = try PondConfig.decode(Data(contentsOf: url)) }
    func exportConfig(to url: URL) throws { try config.encoded().write(to: url, options: .atomic) }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Keys.lastCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastCheck) }
    }
    var skippedVersion: String? {
        get { defaults.string(forKey: Keys.skipped) }
        set { defaults.set(newValue, forKey: Keys.skipped) }
    }
}
