import AppKit
import PondCore
import PondRender

/// Desktop-wallpaper mode: one borderless window per screen at the desktop level (below the icons).
/// The windows ignore the mouse; a global monitor watches clicks and feeds only when the click lands on bare desktop.
final class WallpaperController {
    private var windows: [(NSWindow, PondView)] = []
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var frameTimer: Timer?
    private let state: AppState

    init(state: AppState) { self.state = state }

    var isActive: Bool { !windows.isEmpty }
    var views: [PondView] { windows.map { $0.1 } }

    func start() {
        guard windows.isEmpty else { return }
        buildWindows()
        // one timer drives every screen's pond (see PondView.externallyDriven)
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (w, v) in self.windows where w.isVisible { v.renderFrame() }
        }
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in self?.handleClick() }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.handleMove() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    func stop() {
        frameTimer?.invalidate()
        frameTimer = nil
        for (w, _) in windows { w.orderOut(nil) }
        windows.removeAll()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = moveMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        clickMonitor = nil; moveMonitor = nil; screenObserver = nil
    }

    func apply(config: PondConfig) { for (_, v) in windows { v.apply(config: config) } }

    private func rebuild() {
        for (w, _) in windows { w.orderOut(nil) }
        windows.removeAll()
        buildWindows()
    }

    private func buildWindows() {
        for screen in NSScreen.screens {
            // global coordinates, no `screen:` argument: with it, AppKit reads the rect relative to that screen
            // and a secondary display's window lands offset by its origin twice
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            let bg = Palette.make(state.config.global).background
            w.backgroundColor = NSColor(srgbRed: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1)
            let v = PondView(frame: NSRect(origin: .zero, size: screen.frame.size), config: state.config, interactive: false)
            v.autoresizingMask = [.width, .height]
            v.externallyDriven = true
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFront(nil)
            w.setFrame(screen.frame, display: true)   // again once on screen, in case the first was constrained
            windows.append((w, v))
        }
    }

    /// The wallpaper window (and point inside its view) under a screen point (bottom-left origin).
    private func target(at p: NSPoint) -> (PondView, NSPoint)? {
        for (w, v) in windows where w.frame.contains(p) {
            return (v, NSPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY))
        }
        return nil
    }

    private func handleClick() {
        guard state.wallpaperClickFeeds else { return }
        let p = NSEvent.mouseLocation
        guard WallpaperController.isBareDesktop(at: p), let (v, local) = target(at: p) else { return }
        v.feed(atViewPoint: local)
    }

    private func handleMove() {
        let p = NSEvent.mouseLocation
        guard let (v, local) = target(at: p) else { return }
        v.pointer(atViewPoint: local)
    }

    /// True if no ordinary window, panel, the Dock or the menu bar sits under the point.
    /// Window bounds and layers are readable without the Screen Recording permission.
    static func isBareDesktop(at p: NSPoint) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        // CG window bounds use a top-left origin on the primary screen
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let q = CGPoint(x: p.x, y: primaryHeight - p.y)
        let me = ProcessInfo.processInfo.processIdentifier
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let alpha = w[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0.01 else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.contains(q) { return false }
        }
        return true
    }
}
