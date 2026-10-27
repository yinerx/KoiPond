import AppKit
import SwiftUI
import Combine
import Metal
import PondCore
import PondRender

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let state = AppState()
    lazy var updater = UpdateChecker(state: state)
    lazy var wallpaper = WallpaperController(state: state)
    private var pondWindow: NSWindow?
    private var pondView: PondView?
    private let windowDriver = PondDriver()
    private var configWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        buildStatusItem()

        // every config change reaches every pond, live
        state.$config.dropFirst().sink { [weak self] c in
            self?.pondView?.apply(config: c)
            self?.wallpaper.apply(config: c)
        }.store(in: &bag)
        state.$windowMode.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { self?.setWindow(on) }
        }.store(in: &bag)
        state.$windowProfile.removeDuplicates().sink { [weak self] p in
            self?.pondView?.profile = p
            self?.windowDriver.kick()
        }.store(in: &bag)
        state.$wallpaperProfile.removeDuplicates().sink { [weak self] p in
            self?.wallpaper.setProfile(p)
        }.store(in: &bag)
        state.$wallpaperMode.removeDuplicates().sink { [weak self] on in
            DispatchQueue.main.async { self?.setWallpaper(on) }
        }.store(in: &bag)

        if MTLCreateSystemDefaultDevice() == nil {
            let a = NSAlert(); a.messageText = "这台 Mac 不支持 Metal"; a.informativeText = "KoiPond 需要 Metal 才能绘制池塘。"; a.runModal()
        }
        updater.checkOnLaunchIfDue()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { state.windowMode = true; pondWindow?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ note: Notification) { state.save(state.config) }

    // MARK: modes

    private func setWindow(_ on: Bool) {
        if on {
            if pondWindow == nil { makePondWindow() }
            pondWindow?.makeKeyAndOrderFront(nil)
            windowDriver.kick()
        } else {
            pondWindow?.orderOut(nil)   // the driver notices the window is gone and stops
        }
        updateActivationPolicy()
    }

    private func setWallpaper(_ on: Bool) {
        if on { wallpaper.start() } else { wallpaper.stop() }
        updateActivationPolicy()
    }

    /// A Dock icon only while there is a normal window to show; wallpaper-only mode lives in the menu bar.
    private func updateActivationPolicy() {
        let wantsDock = state.windowMode || (configWindow?.isVisible ?? false)
        NSApp.setActivationPolicy(wantsDock ? .regular : .accessory)
        if wantsDock { NSApp.activate(ignoringOtherApps: true) }
    }

    private func makePondWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "KoiPond"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("KoiPondMainWindow")
        if w.frame.origin == .zero { w.center() }
        w.minSize = NSSize(width: 360, height: 260)
        w.collectionBehavior = [.fullScreenPrimary]
        let v = PondView(frame: frame, config: state.config, interactive: true)
        v.profile = state.windowProfile
        v.autoresizingMask = [.width, .height]
        w.contentView = v
        w.delegate = self
        pondWindow = w
        pondView = v
        windowDriver.add(v)
    }

    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        if w === pondWindow {
            state.windowMode = false
            if !state.wallpaperMode {
                // nothing left on screen: keep running in the menu bar
                updateActivationPolicy()
            }
        } else if w === configWindow {
            DispatchQueue.main.async { self.updateActivationPolicy() }
        }
    }

    // MARK: config window

    @objc func openConfig() {
        if configWindow == nil {
            let host = NSHostingController(rootView: ConfigPanel(state: state, updater: updater))
            let w = NSWindow(contentViewController: host)
            w.title = "KoiPond 配置"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 860, height: 640))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("KoiPondConfigWindow")
            w.delegate = self
            configWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        configWindow?.center()
        configWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "关于 KoiPond", action: #selector(about), keyEquivalent: "")
        app.addItem(withTitle: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "配置…", action: #selector(openConfig), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 KoiPond", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "退出 KoiPond", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "显示")
        view.addItem(withTitle: "窗口", action: #selector(toggleWindow), keyEquivalent: "1")
        view.addItem(withTitle: "桌面壁纸", action: #selector(toggleWallpaper), keyEquivalent: "2")
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "进入全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        view.delegate = self
        viewItem.submenu = view
        main.addItem(viewItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "fish", accessibilityDescription: "KoiPond")
            if b.image == nil { b.title = "🐟" }
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt each time it opens, so checkmarks and presets are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem?.menu {
            menu.removeAllItems()
            let w = menu.addItem(withTitle: "窗口", action: #selector(toggleWindow), keyEquivalent: "")
            w.state = state.windowMode ? .on : .off
            let p = menu.addItem(withTitle: "桌面壁纸", action: #selector(toggleWallpaper), keyEquivalent: "")
            p.state = state.wallpaperMode ? .on : .off
            menu.addItem(.separator())
            let presets = NSMenu()
            for (i, preset) in Preset.allCases.enumerated() {
                let it = presets.addItem(withTitle: preset.displayName, action: #selector(applyPreset(_:)), keyEquivalent: "")
                it.tag = i; it.target = self
            }
            menu.addItem(withTitle: "预设", action: nil, keyEquivalent: "").submenu = presets
            menu.addItem(withTitle: "配置…", action: #selector(openConfig), keyEquivalent: ",")
            menu.addItem(.separator())
            let saver = NSMenu()
            saver.addItem(withTitle: "安装屏幕保护程序", action: #selector(installSaver), keyEquivalent: "").target = self
            saver.addItem(withTitle: "同步当前配置到屏保", action: #selector(syncSaver), keyEquivalent: "").target = self
            menu.addItem(withTitle: "屏幕保护程序", action: nil, keyEquivalent: "").submenu = saver
            menu.addItem(withTitle: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 KoiPond", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for it in menu.items where it.target == nil && it.action != #selector(NSApplication.terminate(_:)) { it.target = self }
        } else {
            for it in menu.items {
                if it.action == #selector(toggleWindow) { it.state = state.windowMode ? .on : .off }
                if it.action == #selector(toggleWallpaper) { it.state = state.wallpaperMode ? .on : .off }
            }
        }
    }

    @objc func toggleWindow() { state.windowMode.toggle(); ensureSomethingVisible() }
    @objc func toggleWallpaper() { state.wallpaperMode.toggle(); ensureSomethingVisible() }
    private func ensureSomethingVisible() {
        // turning both off would leave only the menu bar icon; that is allowed, but say so once
        if !state.windowMode && !state.wallpaperMode, UserDefaults.standard.bool(forKey: "toldAboutMenuBar") == false {
            UserDefaults.standard.set(true, forKey: "toldAboutMenuBar")
            let a = NSAlert()
            a.messageText = "KoiPond 仍在菜单栏里运行"
            a.informativeText = "点菜单栏上的小鱼图标，可以重新打开窗口或桌面壁纸。"
            a.runModal()
        }
    }
    @objc func applyPreset(_ sender: NSMenuItem) {
        guard Preset.allCases.indices.contains(sender.tag) else { return }
        state.load(preset: Preset.allCases[sender.tag])
    }
    @objc func installSaver() { info("屏幕保护程序", ScreenSaverInstaller.install(config: state.config)) }
    @objc func syncSaver() { info("屏幕保护程序", ScreenSaverInstaller.sync(config: state.config)) }
    @objc func checkUpdates() { updater.check(userInitiated: true) }
    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "KoiPond",
            .applicationVersion: UpdateChecker.currentVersion,
            .credits: NSAttributedString(string: "字符网格风格的池塘。点击水面撒饵，锦鲤会游过来吃。\nhttps://github.com/\(UpdateChecker.repo)"),
        ])
    }
    private func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}
