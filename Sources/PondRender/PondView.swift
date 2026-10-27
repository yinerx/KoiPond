import AppKit
import MetalKit
import PondCore

/// The pond on screen. Used by the app window, the desktop-wallpaper windows and the screen saver.
public final class PondView: MTKView, MTKViewDelegate {
    public private(set) var world: World
    private let grid = CellGrid()
    private var renderer: GridRenderer?
    private var lastTime: CFTimeInterval = 0
    private var lastPointerTime: CFTimeInterval = 0
    private var fpsAccum: (frames: Int, time: Double) = (0, 0)
    private var trackingArea: NSTrackingArea?
    private var nextAutoFeed: Double = 0

    /// Clicks feed the pond. Off for the screen saver and for wallpaper windows (those get clicks from a global monitor).
    public var interactive: Bool
    /// Seconds between automatic feedings (screen saver); 0 = never.
    public var autoFeedInterval: Double = 0
    /// When true, MetalKit's own per-screen display link is off and the owner calls `renderFrame()`
    /// (the wallpaper's shared timer, the screen saver's frame callback). MetalKit's link stops drawing
    /// for windows it considers off-screen or occluded, which desktop-level windows on other displays can be.
    public var externallyDriven = false { didSet { isPaused = externallyDriven } }

    /// Renders one frame now (simulation advances by real elapsed time).
    public func renderFrame() { draw() }

    public init(frame: NSRect, config: PondConfig, interactive: Bool = true) {
        self.interactive = interactive
        world = World(config: config, width: Double(max(1, frame.width)), height: Double(max(1, frame.height)))
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: dev)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true
        if let dev { renderer = GridRenderer(device: dev, pixelFormat: colorPixelFormat) }
        delegate = self
        let bg = world.palette.background
        clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
    }

    required init(coder: NSCoder) { fatalError("PondView is created in code") }

    public var isMetalAvailable: Bool { renderer != nil }

    /// Applies a configuration live; unchanged groups keep their individuals.
    public func apply(config: PondConfig) { world.apply(config: config) }

    // MARK: drawing

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 1.0 / 60 : min(0.25, now - lastTime)
        lastTime = now
        fpsAccum.frames += 1; fpsAccum.time += dt
        if fpsAccum.time > 0.5 { world.fps = Double(fpsAccum.frames) / fpsAccum.time; fpsAccum = (0, 0) }

        let w = Double(bounds.width), h = Double(bounds.height)
        if abs(w - world.width) > 0.5 || abs(h - world.height) > 0.5 { world.resize(width: w, height: h) }
        if autoFeedInterval > 0 && world.time > nextAutoFeed {
            if nextAutoFeed > 0 {
                world.feed(at: Vec2(Double.random(in: 0.2...0.8) * w, Double.random(in: 0.2...0.8) * h))
            }
            nextAutoFeed = world.time + autoFeedInterval * Double.random(in: 0.6...1.4)
        }
        world.advance(dt)
        grid.resize(width: w, height: h, cellSize: world.config.global.cellSize)
        world.draw(into: grid)
        renderer?.draw(grid: grid, settings: world.config.global, background: world.palette.background, in: self)
    }

    // MARK: input

    /// View point (bottom-left origin) → pond point (top-left origin).
    private func pondPoint(_ p: NSPoint) -> Vec2 { Vec2(Double(p.x), Double(bounds.height - p.y)) }

    /// Feeds at a point in this view's coordinates (used by the wallpaper's global click monitor).
    public func feed(atViewPoint p: NSPoint) { world.feed(at: pondPoint(p)) }
    public func pointer(atViewPoint p: NSPoint) {
        let now = CACurrentMediaTime()
        world.pointerMoved(to: pondPoint(p), dt: lastPointerTime == 0 ? 1.0 / 60 : max(1.0 / 240, now - lastPointerTime))
        lastPointerTime = now
    }

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
}
