import AppKit
import PondCore

/// Installs the screen saver that ships inside the app bundle and hands it the current configuration.
enum ScreenSaverInstaller {
    static let saverName = "KoiPond.saver"

    static var bundledSaver: URL? {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent(saverName),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
    static var installedSaver: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Screen Savers/\(saverName)")
    }
    /// Screen savers run inside Apple's sandboxed "legacyScreenSaver" host; this is its Application Support.
    static var sandboxConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/KoiPond/config.json")
    }

    /// Copies the saver into ~/Library/Screen Savers, syncs the config and opens the Screen Saver settings.
    static func install(config: PondConfig) -> String {
        guard let src = bundledSaver else {
            return "这个版本里没有屏保组件（从源码直接运行时没有）。请使用 GitHub Releases 里的安装包。"
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: installedSaver.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedSaver.path) { try fm.removeItem(at: installedSaver) }
            try fm.copyItem(at: src, to: installedSaver)
            _ = try? UpdateChecker.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", installedSaver.path])
        } catch {
            return "安装失败：\(error.localizedDescription)"
        }
        let synced = sync(config: config)
        if let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        return "已安装到「~/Library/Screen Savers」。在系统设置的屏幕保护程序里选择 KoiPond。" + (synced.hasPrefix("已") ? "" : "\n" + synced)
    }

    @discardableResult
    static func sync(config: PondConfig) -> String {
        do {
            let url = sandboxConfigURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.encoded().write(to: url, options: .atomic)
            return "已同步，屏保下次启动时使用当前配置。"
        } catch {
            return "同步失败：\(error.localizedDescription)"
        }
    }
}
