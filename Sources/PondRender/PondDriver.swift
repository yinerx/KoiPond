import AppKit
import QuartzCore
import PondCore

/// Drives a set of pond views. Each tick renders the views that can be seen, then schedules the next
/// tick at the fastest rate any of them asks for (calm ponds tick slowly). When nothing is visible, or the
/// Mac is asleep, locked, switched to another user or showing a screen saver, the timer stops completely;
/// window and system notifications start it again.
public final class PondDriver: NSObject {
    private var views: [PondView] = []
    private var timer: DispatchSourceTimer?
    /// At display-like rates the timer gets coalesced and drops frames; a display link follows the screen's
    /// refresh instead. Low rates keep the timer: coalescing is exactly what saves power there.
    private var link: CADisplayLink?
    private var linkFPS: Double = 0
    private var interval: Double = 0
    private var observers: [NSObjectProtocol] = []
    /// When each view last rendered: a calm screen keeps its own slow rate while another screen is busy.
    private var lastRender: [ObjectIdentifier: CFTimeInterval] = [:]

    public override init() {
        super.init()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, self.views.contains(where: { $0.window === w }) else { return }
            self.kick()
        })
        observers.append(nc.addObserver(forName: SystemActivity.changed, object: nil, queue: .main) { [weak self] _ in self?.kick() })
        // Low Power Mode and thermal changes switch the effective profile
        observers.append(nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.kick() })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.kick() })
        _ = SystemActivity.shared
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        timer?.cancel()
        link?.invalidate()
    }

    public func add(_ v: PondView) {
        views.append(v)
        v.onActivity = { [weak self] in self?.wake() }
        kick()
    }
    public func removeAll() { views.removeAll(); lastRender.removeAll(); stop() }

    /// Input happened: make sure the next frame comes at the fast rate. Never renders by itself, so a
    /// stream of mouse events cannot push the frame rate past the profile.
    public func wake() {
        guard timer != nil || link != nil else { kick(); return }
        if link != nil { return }                       // already at the display's rate
        let fast = views.map { $0.effectiveProfile.activeFPS }.max() ?? 30
        if interval > 1 / fast + 0.0005 { schedule(1 / fast) }
    }

    /// Render now and re-plan (new view, a window uncovered, the Mac woke up…).
    public func kick() {
        guard !views.isEmpty else { stop(); return }
        if interval == 0 { views.forEach { $0.resume() } }   // coming back from a stop
        lastRender.removeAll()                                // render everyone now
        tick()
    }

    /// Timer ticks so far (self-test diagnostics).
    public private(set) var ticks = 0

    private func tick() {
        ticks += 1
        guard !SystemActivity.shared.isSuspended else { stop(); return }
        var fps = 0.0
        let now = CACurrentMediaTime()
        for v in views {
            guard v.isVisibleForRendering else { v.noteHidden(); continue }
            v.noteVisible()
            let want = v.desiredFPS, id = ObjectIdentifier(v)
            // due when three quarters of its frame interval have passed: display-link ticks jitter, and a
            // tighter cut skipped every early tick (~10 frames/s lost at 60 Hz); on 120 Hz it still holds 60
            if now - (lastRender[id] ?? 0) >= 0.75 / want {
                v.renderFrame()
                lastRender[id] = now
            }
            fps = max(fps, want)
        }
        guard fps > 0 else { stop(); return }     // nothing on screen: wait for a notification
        if fps >= 50, let v = views.first(where: { $0.isVisibleForRendering }) {
            useDisplayLink(on: v, fps: fps)
        } else {
            dropDisplayLink()
            schedule(1 / fps)
        }
    }

    private func useDisplayLink(on view: PondView, fps: Double) {
        if timer != nil { timer?.cancel(); timer = nil; interval = 0 }
        if link == nil {
            let l = view.displayLink(target: self, selector: #selector(linkFired(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            linkFPS = 0
        }
        if linkFPS != fps {
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(30, fps)), maximum: Float(fps), preferred: Float(fps))
            linkFPS = fps
        }
        interval = 1 / fps
    }

    private func dropDisplayLink() {
        link?.invalidate()
        link = nil
        linkFPS = 0
    }

    @objc private func linkFired(_ l: CADisplayLink) { tick() }

    private func schedule(_ iv: Double) {
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            interval = -1
        }
        guard abs(iv - interval) > 0.0005 else { return }
        interval = iv
        // 10 % leeway lets macOS coalesce wake-ups with other timers
        timer?.schedule(deadline: .now() + iv, repeating: iv, leeway: .microseconds(max(500, Int(iv * 100_000))))
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        dropDisplayLink()
        interval = 0
    }
}

/// Whether anyone can see the screen at all. Posts `changed` when that flips.
public final class SystemActivity {
    public static let shared = SystemActivity()
    public static let changed = Notification.Name("KoiPondSystemActivityChanged")
    public private(set) var reasons: Set<String> = []
    public var isSuspended: Bool { !reasons.isEmpty }
    private var tokens: [NSObjectProtocol] = []

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        pair(ws, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display asleep")
        pair(ws, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system asleep")
        pair(ws, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "other user")
        let dn = DistributedNotificationCenter.default()
        pair(dn, Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"), "locked")
        pair(dn, Notification.Name("com.apple.screensaver.didstart"), Notification.Name("com.apple.screensaver.didstop"), "screen saver")
    }

    private func pair(_ center: NotificationCenter, _ on: Notification.Name, _ off: Notification.Name, _ reason: String) {
        tokens.append(center.addObserver(forName: on, object: nil, queue: .main) { [weak self] _ in self?.set(reason, true) })
        tokens.append(center.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in self?.set(reason, false) })
    }

    private func set(_ reason: String, _ on: Bool) {
        let before = isSuspended
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        if before != isSuspended { NotificationCenter.default.post(name: SystemActivity.changed, object: self) }
    }
}
