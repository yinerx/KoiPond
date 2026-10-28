import AppKit
import MetalKit
import QuartzCore
import Darwin
import PondCore

/// The pond on screen. Used by the app window, the desktop-wallpaper windows and the screen saver.
/// It never drives itself: a `PondDriver` (or the screen saver's frame callback) calls `renderFrame()`
/// at the rate `desiredFPS` asks for, and only while the view can actually be seen.
public final class PondView: MTKView, MTKViewDelegate {
    public private(set) var world: World
    private let grid = CellGrid()
    private var renderer: GridRenderer?
    private var lastTime: CFTimeInterval = 0
    private var lastPointerTime: CFTimeInterval = 0
    private var trackingArea: NSTrackingArea?
    private var nextAutoFeed: Double = 0
    private var occlusionTrusted = false
    private var stats = Stats()

    /// Clicks feed the pond. Off for the screen saver and for wallpaper windows (those get clicks from a global monitor).
    public var interactive: Bool
    /// Seconds between automatic feedings (screen saver); 0 = never.
    public var autoFeedInterval: Double = 0
    /// Frame rates and render resolution. Low Power Mode or a hot Mac switch to `.saver` on their own.
    public var profile: PowerProfile = .smooth { didSet { updateDrawableSize() } }
    /// Set by the owner when it knows the view is hidden (the wallpaper checks screen coverage itself).
    public var coveredByOtherWindows = false
    private var lastPresented = false
    /// Counters for the self-test: frames simulated, frames drawn (not skipped), frames confirmed on screen.
    public private(set) var framesRendered = 0
    public private(set) var framesDrawn = 0
    public var framesOnScreen: Int { renderer?.screenUpdates ?? 0 }
    public var framesPresented: Int { renderer?.presentedCallbacks ?? 0 }
    /// Wall-clock seconds spent inside renderFrame, waits included (self-test diagnostics).
    public private(set) var renderWallSeconds = 0.0
    /// Why the view is or isn't rendered (self-test diagnostics).
    public var visibilityDebug: String {
        guard let w = window else { return "no window" }
        return "visible=\(w.isVisible) occlusion=\(w.occlusionState.rawValue) (visible bit \(w.occlusionState.contains(.visible))) " +
            "trusted=\(occlusionTrusted) covered=\(coveredByOtherWindows) level=\(w.level.rawValue) → render=\(isVisibleForRendering)" +
            " presented callbacks=\(renderer?.presentedCallbacks ?? 0)"
    }

    public init(frame: NSRect, config: PondConfig, interactive: Bool = true) {
        self.interactive = interactive
        world = World(config: config, width: Double(max(1, frame.width)), height: Double(max(1, frame.height)))
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: dev)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        // frames come from renderFrame(); MetalKit's own display link stays off
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = false
        if let metal = layer as? CAMetalLayer {
            metal.maximumDrawableCount = 2          // raised to 3 for the smooth profile (see updateDrawableSize)
            metal.magnificationFilter = .linear     // reduced-resolution profiles are scaled up smoothly
            metal.isOpaque = true
        }
        if let dev { renderer = GridRenderer(device: dev, pixelFormat: colorPixelFormat) }
        delegate = self
        let bg = world.palette.background
        clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
        updateDrawableSize()
    }

    required init(coder: NSCoder) { fatalError("PondView is created in code") }

    public var isMetalAvailable: Bool { renderer != nil }

    /// Applies a configuration live; unchanged groups keep their individuals.
    public func apply(config: PondConfig) { world.apply(config: config); renderer?.invalidate() }

    // MARK: pacing

    var effectiveProfile: PowerProfile {
        profile.effective(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                          thermalSerious: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue)
    }

    /// The frame rate this view wants right now: fast while something is happening, slow when the pond is calm.
    public var desiredFPS: Double {
        let p = effectiveProfile
        return p.fps(busy: world.wantsFastFrames(hold: p.activeHold))
    }

    /// False when the window is closed, minimised, hidden or fully covered.
    /// Until a window has reported itself visible once, occlusion is not trusted (desktop-level windows
    /// may never report it), so such a view keeps rendering rather than freezing.
    public var isVisibleForRendering: Bool {
        guard !coveredByOtherWindows, let w = window, w.isVisible, !w.isMiniaturized, !isHiddenOrHasHiddenAncestor else { return false }
        if w.occlusionState.contains(.visible) { occlusionTrusted = true; return true }
        return !occlusionTrusted
    }

    /// Advances the pond by the real time since the last frame and draws it (skipped if nothing changed).
    @discardableResult
    public func renderFrame() -> Bool {
        let t0 = CACurrentMediaTime()
        updateDrawableSize()
        // Must go through MTKView.draw(): it hands out a fresh drawable for this frame and takes it back
        // afterwards. Rendering outside it keeps re-presenting one drawable, and the screen stops updating.
        lastPresented = false
        draw()
        let presented = lastPresented
        framesRendered += 1
        if presented { framesDrawn += 1 }
        renderWallSeconds += CACurrentMediaTime() - t0
        stats.add(cpu: CACurrentMediaTime() - t0, presented: presented, at: t0)
        if world.config.global.showFPS, stats.due(at: t0) { world.hudLines = stats.lines(view: self) }
        return presented
    }

    private func step(now: CFTimeInterval) -> Bool {
        let dt = lastTime == 0 ? 1.0 / 60 : min(0.25, now - lastTime)
        lastTime = now
        let w = Double(bounds.width), h = Double(bounds.height)
        if abs(w - world.width) > 0.5 || abs(h - world.height) > 0.5 { world.resize(width: w, height: h) }
        if autoFeedInterval > 0 && world.time > nextAutoFeed {
            if nextAutoFeed > 0 { world.feed(at: Vec2(Double.random(in: 0.2...0.8) * w, Double.random(in: 0.2...0.8) * h)) }
            nextAutoFeed = world.time + autoFeedInterval * Double.random(in: 0.6...1.4)
        }
        world.advance(dt)
        grid.resize(width: w, height: h, cellSize: world.config.global.cellSize)
        world.draw(into: grid)
        return renderer?.draw(grid: grid, settings: world.config.global, background: world.palette.background, in: self) ?? false
    }

    /// After a pause: don't fast-forward the pond, and redraw even if the picture did not change.
    public func resume() { lastTime = 0; renderer?.invalidate() }

    // MARK: resolution

    /// Drawable pixels = points × screen scale × the profile's resolution scale.
    private func updateDrawableSize() {
        // 60 fps from a timer that is not locked to the display needs a third buffer, or frames wait for one;
        // the slow profiles keep two (less memory, and they never get close to the refresh rate)
        if let metal = layer as? CAMetalLayer {
            let want = effectiveProfile.activeFPS >= 50 ? 3 : 2
            if metal.maximumDrawableCount != want { metal.maximumDrawableCount = want }
        }
        let backing = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let s = max(0.25, backing * effectiveProfile.resolutionScale)
        let size = CGSize(width: max(1, (Double(bounds.width) * s).rounded()), height: max(1, (Double(bounds.height) * s).rounded()))
        if drawableSize != size { drawableSize = size; renderer?.invalidate() }
    }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateDrawableSize() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); occlusionTrusted = false; updateDrawableSize() }

    // MARK: MTKViewDelegate (only reached through renderFrame → step)

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    public func draw(in view: MTKView) { lastPresented = step(now: CACurrentMediaTime()) }

    // MARK: input

    /// View point (bottom-left origin) → pond point (top-left origin).
    private func pondPoint(_ p: NSPoint) -> Vec2 { Vec2(Double(p.x), Double(bounds.height - p.y)) }

    /// Feeds at a point in this view's coordinates (used by the wallpaper's global click monitor).
    public func feed(atViewPoint p: NSPoint) { world.feed(at: pondPoint(p)); onActivity?() }
    public func pointer(atViewPoint p: NSPoint) {
        let now = CACurrentMediaTime()
        world.pointerMoved(to: pondPoint(p), dt: lastPointerTime == 0 ? 1.0 / 60 : max(1.0 / 240, now - lastPointerTime))
        lastPointerTime = now
        if world.pointerSpeed > 300 { onActivity?() }
    }
    /// Called on input so a slow-running driver can speed up at once.
    public var onActivity: (() -> Void)?

    public override var acceptsFirstResponder: Bool { interactive }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { interactive }

    public override func mouseDown(with event: NSEvent) {
        guard interactive else { return super.mouseDown(with: event) }
        feed(atViewPoint: convert(event.locationInWindow, from: nil))
    }
    public override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        pointer(atViewPoint: convert(event.locationInWindow, from: nil))
    }
    public override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    public override func mouseExited(with event: NSEvent) { world.pointerExited() }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: performance overlay

    struct Stats {
        var frames = 0, presented = 0, cpu = 0.0, since: CFTimeInterval = 0
        mutating func add(cpu c: Double, presented p: Bool, at t: CFTimeInterval) {
            if since == 0 { since = t }
            frames += 1; cpu += c; if p { presented += 1 }
        }
        func due(at t: CFTimeInterval) -> Bool { t - since >= 1 }
        mutating func lines(view: PondView) -> [String] {
            let now = CACurrentMediaTime(), span = max(0.001, now - since)
            let fps = Double(frames) / span, drawn = Double(presented) / span
            let ms = frames > 0 ? cpu / Double(frames) * 1000 : 0
            let p = view.effectiveProfile
            let out = [
                String(format: "%.0f fps (drawn %.0f, on screen %.0f)  target %.0f  %@", fps, drawn,
                       view.renderer?.takeScreenUpdateRate(span) ?? 0, view.desiredFPS, p.rawValue),
                String(format: "%.2f ms/frame  %d cells  %.0fx%.0f px", ms, view.renderer?.lastCellCount ?? 0,
                       Double(view.drawableSize.width), Double(view.drawableSize.height)),
                String(format: "memory %.0f MB", PondView.footprintMB()),
            ]
            frames = 0; presented = 0; cpu = 0; since = now
            return out
        }
    }

    /// The process's memory footprint (what Activity Monitor shows as "Memory"), in MB.
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
