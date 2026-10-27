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

    /// Hands the saver to macOS's own installer: opening a .saver shows the system's "install screen saver"
    /// prompt, installs it and lands in Screen Saver settings with KoiPond selected — on every macOS version,
    /// unlike a Settings deep link whose pane identifier changes between releases.
    static func install(config: PondConfig) -> String {
        guard let src = bundledSaver else {
            return "这个版本里没有屏保组件（从源码直接运行时没有）。请使用 GitHub Releases 里的安装包。"
        }
        sync(config: config)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("KoiPondSaver-\(UUID().uuidString)", isDirectory: true)
        let staged = staging.appendingPathComponent(saverName)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: staged)
            // an app opened via right-click → Open still carries quarantine; the installer would refuse the copy
            _ = try? UpdateChecker.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        } catch {
            return installManually(src: src, reason: error.localizedDescription)
        }
        NSWorkspace.shared.open(staged, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "屏幕保护程序"
                a.informativeText = installManually(src: src, reason: error.localizedDescription)
                a.runModal()
            }
        }
        return "已打开系统的安装窗口。选择「仅为此用户安装」后，系统设置会跳到屏幕保护程序并选中 KoiPond。"
    }

    /// Fallback: copy it ourselves and open System Settings near the right place.
    static func installManually(src: URL, reason: String) -> String {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: installedSaver.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedSaver.path) { try fm.removeItem(at: installedSaver) }
            try fm.copyItem(at: src, to: installedSaver)
            _ = try? UpdateChecker.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", installedSaver.path])
        } catch {
            return "安装失败：\(error.localizedDescription)"
        }
        for id in ["com.apple.ScreenSaver-Settings.extension", "com.apple.Wallpaper-Settings.extension"] {
            if let url = URL(string: "x-apple.systempreferences:\(id)"), NSWorkspace.shared.open(url) { break }
        }
        return "系统安装窗口没能打开（\(reason)），已直接装到「~/Library/Screen Savers」。请在系统设置的「屏幕保护程序」里选择 KoiPond。"
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
