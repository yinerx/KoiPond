import AppKit
import Darwin
import PondCore
import PondRender

/// `KoiPond --selftest [seconds]`: runs the window and the wallpaper on this Mac and checks what a user
/// would see. Prints a report and exits non-zero if a check fails (CI runs it before every release).
///  1. visible  — every pond must reach the screen with fresh frames, at roughly its profile's rate;
///  2. covered  — with every screen hidden behind a window, the ponds must stop and the CPU go quiet.
final class SelfTest {
    private let state: AppState
    private let seconds: Double
    private let driver = PondDriver()
    var windowDriver: PondDriver { driver }
    private var pondWindow: NSWindow!
    private var pond: PondView!
    private var wallpaper: WallpaperController!
    private var covers: [NSWindow] = []
    private var lines: [String] = []
    private var failed = false

    init(state: AppState, seconds: Double) { self.state = state; self.seconds = max(3, seconds) }

    func run() {
        NSApp.setActivationPolicy(.regular)
        let frame = NSRect(x: 100, y: 100, width: 900, height: 600)
        pondWindow = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        pond = PondView(frame: NSRect(origin: .zero, size: frame.size), config: Preset.koiPond.config, interactive: true)
        pond.profile = .smooth
        pond.autoresizingMask = [.width, .height]
        pondWindow.contentView = pond
        pondWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        driver.add(pond)
        wallpaper = WallpaperController(state: state)
        wallpaper.start()
        wallpaper.setProfile(.balanced)

        say("KoiPond self-test: \(NSScreen.screens.count) screen(s), \(Int(seconds)) s per phase, Metal: \(pond.isMetalAvailable)")
        after(1.5) {                                   // let windows settle
            self.diagnose("before visible phase")
            self.measure("visible", for: self.seconds) { r in
                self.diagnose("after visible phase")
                self.expect(r.window.onScreen >= 45, "window presents fresh frames (\(f(r.window.onScreen))/s, smooth profile)")
                self.expect(r.window.rendered >= 54, "window renders on every display tick (\(f(r.window.rendered))/s, smooth profile)")
                for (i, w) in r.wallpaper.enumerated() {
                    self.expect(w.onScreen >= 4, "wallpaper \(i + 1) presents fresh frames (\(f(w.onScreen))/s, balanced profile)")
                    self.expect(w.rendered <= 32, "wallpaper \(i + 1) stays near its profile rate (\(f(w.rendered))/s)")
                }
                self.coverEverything()
                self.after(2.5) {                      // occlusion + one coverage poll
                    self.wallpaper.checkCoverageNow()
                    self.measure("covered", for: self.seconds) { r in
                        self.expect(r.window.rendered <= 1, "covered window stops (\(f(r.window.rendered))/s)")
                        for (i, w) in r.wallpaper.enumerated() {
                            self.expect(w.rendered <= 1, "covered wallpaper \(i + 1) stops (\(f(w.rendered))/s)")
                        }
                        self.expect(r.cpu <= 5, "CPU stays low while covered (\(f(r.cpu)) %)")
                        self.finish()
                    }
                }
            }
        }
    }

    private func diagnose(_ when: String) {
        wallpaper.checkCoverageNow()
        say("--- \(when)")
        say("window:      " + pond.visibilityDebug)
        for (i, v) in wallpaper.views.enumerated() { say("wallpaper \(i + 1): " + v.visibilityDebug) }
        say("screens: " + NSScreen.screens.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: "; "))
        say("on-screen windows above the desktop:")
        wallpaper.coverageDebug().forEach(say)
    }

    struct Rates { var rendered = 0.0, drawn = 0.0, onScreen = 0.0 }
    struct Result { var window = Rates(); var wallpaper: [Rates] = []; var cpu = 0.0 }

    // third counter: presented callbacks (a virtual display gives no timestamps, so presentedTime stays 0 there)
    private func counters(_ v: PondView) -> (Int, Int, Int) { (v.framesRendered, v.framesDrawn, v.framesPresented) }

    private func measure(_ phase: String, for s: Double, then: @escaping (Result) -> Void) {
        let views = [pond!] + wallpaper.views
        let start = views.map(counters), cpu0 = SelfTest.cpuSeconds(), t0 = CACurrentMediaTime()
        let ticks0 = driver.ticks, wall0 = pond.renderWallSeconds, frames0 = pond.framesRendered
        after(s) {
            let span = CACurrentMediaTime() - t0
            let end = views.map(self.counters)
            let rates = zip(start, end).map { a, b in
                Rates(rendered: Double(b.0 - a.0) / span, drawn: Double(b.1 - a.1) / span, onScreen: Double(b.2 - a.2) / span)
            }
            let r = Result(window: rates[0], wallpaper: Array(rates.dropFirst()), cpu: (SelfTest.cpuSeconds() - cpu0) / span * 100)
            self.say("[\(phase)] CPU \(f(r.cpu)) %, memory \(f(PondView.footprintMB())) MB")
            let n = self.pond.framesRendered - frames0
            self.say("[\(phase)] window driver ticks \(f(Double(self.driver.ticks - ticks0) / span))/s, " +
                     "wall time per frame \(f(n > 0 ? (self.pond.renderWallSeconds - wall0) / Double(n) * 1000 : 0)) ms")
            for (i, x) in rates.enumerated() {
                self.say("[\(phase)] \(i == 0 ? "window     " : "wallpaper \(i)") rendered \(f(x.rendered))/s, drawn \(f(x.drawn))/s, presented \(f(x.onScreen))/s")
            }
            then(r)
        }
    }

    private func coverEverything() {
        for s in NSScreen.screens {
            let w = NSWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .floating
            w.backgroundColor = .black
            w.isOpaque = true
            w.setFrame(s.frame, display: true)
            w.orderFrontRegardless()
            covers.append(w)
        }
        say("covered every screen with an opaque window")
    }

    private func expect(_ ok: Bool, _ what: String) {
        say((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failed = true }
    }
    private func finish() {
        say(failed ? "SELFTEST FAIL" : "SELFTEST PASS")
        fflush(stdout)
        exit(failed ? 1 : 0)
    }
    private func say(_ s: String) { print(s); fflush(stdout) }
    private func after(_ s: Double, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block) }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return sec(u.ru_utime) + sec(u.ru_stime)
    }
}

private func f(_ x: Double) -> String { String(format: "%.1f", x) }
