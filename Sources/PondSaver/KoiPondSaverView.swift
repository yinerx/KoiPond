import AppKit
import ScreenSaver
import PondCore
import PondRender

/// The screen saver: the same pond, fed automatically every so often (a screen saver gets no clicks).
/// Configuration comes from the copy the app writes with 「同步当前配置到屏保」; otherwise the koi pond preset.
@objc(KoiPondSaverView)
public final class KoiPondSaverView: ScreenSaverView {
    private var pond: PondView?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 60
        wantsLayer = true
        var config = KoiPondSaverView.loadConfig()
        if isPreview { config.global.showCounter = false }
        let v = PondView(frame: bounds, config: config, interactive: false)
        v.autoresizingMask = [.width, .height]
        v.autoFeedInterval = 18
        v.externallyDriven = true           // frames come from animateOneFrame
        addSubview(v)
        pond = v
    }

    public required init?(coder: NSCoder) { super.init(coder: coder) }

    static func loadConfig() -> PondConfig {
        // inside Apple's sandboxed screen-saver host this resolves to its own container
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let url = base.appendingPathComponent("KoiPond/config.json")
            if let data = try? Data(contentsOf: url), let c = try? PondConfig.decode(data) { return c }
        }
        return Preset.koiPond.config
    }

    public override func animateOneFrame() { pond?.renderFrame() }
    public override var hasConfigureSheet: Bool { false }
}
