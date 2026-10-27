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

    /// Installs the saver into ~/Library/Screen Savers ourselves, then opens the screen-saver page of System Settings.
    /// The system's own .saver installer shows its prompt but, on recent macOS, lands on the wrong page;
    /// so we skip it and find the page's identifier on this Mac (see `SettingsPane`).
    static func install(config: PondConfig) -> String {
        guard let src = bundledSaver else {
            return "这个版本里没有屏保组件（从源码直接运行时没有）。请使用 GitHub Releases 里的安装包。"
        }
        sync(config: config)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: installedSaver.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: installedSaver.path) { try fm.removeItem(at: installedSaver) }
            try fm.copyItem(at: src, to: installedSaver)
            // an app opened via right-click → Open still carries quarantine; the saver would be refused
            _ = try? UpdateChecker.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", installedSaver.path])
        } catch {
            // last resort: let macOS install it through its own prompt
            NSWorkspace.shared.open(src)
            return "直接安装失败（\(error.localizedDescription)），已改用系统的安装窗口。"
        }
        guard let pane = screenSaverPane() else {
            openSettings(nil)
            return "已安装到「~/Library/Screen Savers」。这台 Mac 上没找到屏幕保护程序的设置页，已打开系统设置，请在里面找到「屏幕保护程序」并选择 KoiPond。"
        }
        openSettings(SettingsPane.url(for: pane))
        return "已安装到「~/Library/Screen Savers」，并打开了「\(pane.name.isEmpty ? pane.identifier : pane.name)」设置页，请在列表里选择 KoiPond。（设置页标识：\(pane.identifier)）"
    }

    /// The System Settings pages this Mac has, read from their extension bundles.
    static func settingsPanes() -> [SettingsPane.Candidate] {
        let dir = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "appex" }.compactMap { url in
            guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
            let info = b.localizedInfoDictionary ?? [:], base = b.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"] ?? base["CFBundleDisplayName"] ?? base["CFBundleName"]) as? String
            return SettingsPane.Candidate(identifier: id, name: name ?? fm.displayName(atPath: url.path))
        }
    }

    static func screenSaverPane() -> SettingsPane.Candidate? { SettingsPane.screenSaver(in: settingsPanes()) }

    /// Quits System Settings if it is open (so it lists the newly installed saver), then opens `url`.
    static func openSettings(_ url: URL?) {
        let target = url ?? URL(string: "x-apple.systempreferences:")!
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
        guard !running.isEmpty else { NSWorkspace.shared.open(target); return }
        running.forEach { $0.terminate() }
        var tries = 0
        func wait() {
            tries += 1
            if running.allSatisfy({ $0.isTerminated }) || tries > 30 { NSWorkspace.shared.open(target); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait() }
        }
        wait()
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
