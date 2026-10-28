import AppKit
import QuartzCore
import PondCore
import PondRender

/// Desktop-wallpaper mode: one borderless window per screen at the desktop level (below the icons).
/// The windows ignore the mouse; a global monitor watches clicks and feeds only when the click lands on bare desktop.
final class WallpaperController {
    private var windows: [(NSWindow, PondView)] = []
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private let driver = PondDriver()
    private var coverageTimer: DispatchSourceTimer?
    private var lastMove: CFTimeInterval = 0
    /// Self-test hook: treat every screen as covered without opening covering windows.
    var forceCovered = false { didSet { updateCoverage() } }
    private let state: AppState

    init(state: AppState) { self.state = state }

    var isActive: Bool { !windows.isEmpty }
    var views: [PondView] { windows.map { $0.1 } }
    /// Runs the coverage check now (the self-test does not want to wait for the next poll).
    func checkCoverageNow() { updateCoverage() }

    /// Windows the coverage check counts, one line each (self-test diagnostics).
    func coverageDebug() -> [String] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return ["window list unavailable"] }
        let mine = Set(windows.map { $0.0.windowNumber })
        return info.compactMap { w in
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0,
                  let num = w[kCGWindowNumber as String] as? Int, !mine.contains(num),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let alpha = w[kCGWindowAlpha as String] as? CGFloat ?? 1
            let counted = Coverage.counts(layer: layer, alpha: Double(alpha))
            return "  \(counted ? "counts " : "ignored") \(owner) layer \(layer) alpha \(String(format: "%.2f", Double(alpha))) at \(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
        }
    }

    func start() {
        guard windows.isEmpty else { return }
        buildWindows()
        startCoveragePoll()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in self?.handleClick() }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.handleMove() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    func stop() {
        driver.removeAll()
        coverageTimer?.cancel()
        coverageTimer = nil
        for (w, _) in windows { w.orderOut(nil) }
        windows.removeAll()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let m = moveMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        clickMonitor = nil; moveMonitor = nil; screenObserver = nil
    }

    func apply(config: PondConfig) { for (_, v) in windows { v.apply(config: config) }; driver.kick() }
    func setProfile(_ p: PowerProfile) { for (_, v) in windows { v.profile = p }; driver.kick() }

    private func rebuild() {
        driver.removeAll()
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
            v.memoryLean = true
            v.profile = state.wallpaperProfile
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFront(nil)
            w.setFrame(screen.frame, display: true)   // again once on screen, in case the first was constrained
            windows.append((w, v))
            driver.add(v)
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
        // the global monitor can fire hundreds of times a second; the pond needs far fewer
        let now = CACurrentMediaTime()
        guard now - lastMove > 1.0 / 30 else { return }
        lastMove = now
        let p = NSEvent.mouseLocation
        guard let (v, local) = target(at: p), v.isVisibleForRendering else { return }
        v.pointer(atViewPoint: local)
    }

    // MARK: coverage

    /// Once a second: is each screen's wallpaper hidden behind other windows (a full-screen app, zoomed
    /// windows)? Desktop-level windows don't get dependable occlusion reports, so we look ourselves.
    /// A covered screen's pond stops completely; this poll is what starts it again.
    private func startCoveragePoll() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.updateCoverage() }
        t.resume()
        coverageTimer = t
    }

    private func updateCoverage() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        // every window but the wallpaper itself (KoiPond's own pond window can hide the wallpaper too)
        let mine = Set(windows.map { $0.0.windowNumber })
        var rects: [Coverage.Rect] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int,
                  Coverage.counts(layer: layer, alpha: Double(w[kCGWindowAlpha as String] as? CGFloat ?? 1)),
                  let num = w[kCGWindowNumber as String] as? Int, !mine.contains(num),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            rects.append(Coverage.Rect(x: Double(b["X"] ?? 0), y: Double(b["Y"] ?? 0), w: Double(b["Width"] ?? 0), h: Double(b["Height"] ?? 0)))
        }
        // CG bounds: top-left origin on the primary screen; AppKit frames: bottom-left
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        var changed = false
        for (w, v) in windows {
            let f = w.frame
            let screen = Coverage.Rect(x: Double(f.minX), y: primaryHeight - Double(f.maxY), w: Double(f.width), h: Double(f.height))
            let covered = forceCovered || Coverage.isCovered(screen, by: rects)
            if v.coveredByOtherWindows != covered { v.coveredByOtherWindows = covered; changed = true }
        }
        if changed { driver.kick() }
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
