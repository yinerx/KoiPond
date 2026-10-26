import Foundation

/// Every colour the pond uses, per theme.
public struct Palette: Sendable {
    public var background: RGBA
    public var shadow: RGBA        // dark tiles under/around swimmers
    public var body: RGBA          // koi white
    public var bodyEdge: RGBA
    public var red: RGBA
    public var orange: RGBA
    public var black: RGBA
    public var gold: RGBA
    public var asagi: RGBA
    public var fin: RGBA
    public var eye: RGBA
    public var ripple: RGBA
    public var pellet: RGBA
    public var ink: RGBA
    public var text: RGBA
    public var whale: RGBA
    public var whaleLight: RGBA
    public var turtleShell: RGBA
    public var turtleShellDark: RGBA
    public var turtleSkin: RGBA
    public var squid: RGBA
    public var squidSpot: RGBA
    public var shrimp: RGBA
    public var leaf: RGBA
    public var leafDark: RGBA
    public var leafVein: RGBA
    public var petal: RGBA
    public var stamen: RGBA

    public static let dark = Palette(
        background: RGBA(0x1b, 0x1a, 0x19), shadow: RGBA(0x2b, 0x2a, 0x28),
        body: RGBA(0x9e, 0x9a, 0x94), bodyEdge: RGBA(0x5c, 0x59, 0x55),
        red: RGBA(0xb4, 0x3e, 0x1c), orange: RGBA(0xc9, 0x6b, 0x24), black: RGBA(0x2e, 0x31, 0x42),
        gold: RGBA(0xc9, 0x9a, 0x3a), asagi: RGBA(0x6f, 0x86, 0x9a),
        fin: RGBA(0x8a, 0x86, 0x80, 200), eye: RGBA(0xe8, 0xe4, 0xde),
        ripple: RGBA(0x8f, 0x8b, 0x85), pellet: RGBA(0xd8, 0x8a, 0x3c), ink: RGBA(0x0b, 0x0b, 0x10),
        text: RGBA(0x8a, 0x86, 0x80),
        whale: RGBA(0x4f, 0x5f, 0x75), whaleLight: RGBA(0x8d, 0x9c, 0xae),
        turtleShell: RGBA(0x6a, 0x74, 0x3c), turtleShellDark: RGBA(0x45, 0x4c, 0x26), turtleSkin: RGBA(0x8d, 0x96, 0x68),
        squid: RGBA(0xb8, 0x7d, 0x76, 230), squidSpot: RGBA(0x7a, 0x3a, 0x34),
        shrimp: RGBA(0xd9, 0x9a, 0x86, 220),
        leaf: RGBA(0x3e, 0x6a, 0x38), leafDark: RGBA(0x2b, 0x4c, 0x28), leafVein: RGBA(0x72, 0x9e, 0x58),
        petal: RGBA(0xe2, 0x9e, 0xb4), stamen: RGBA(0xee, 0xcd, 0x6a)
    )

    public static let light = Palette(
        background: RGBA(0xf1, 0xee, 0xe8), shadow: RGBA(0xdf, 0xdb, 0xd3),
        body: RGBA(0xfb, 0xfa, 0xf7), bodyEdge: RGBA(0xb9, 0xb4, 0xab),
        red: RGBA(0xc8, 0x46, 0x1f), orange: RGBA(0xdb, 0x7a, 0x2c), black: RGBA(0x34, 0x37, 0x48),
        gold: RGBA(0xd6, 0xa6, 0x3f), asagi: RGBA(0x7d, 0x95, 0xab),
        fin: RGBA(0xa8, 0xa2, 0x98, 200), eye: RGBA(0x22, 0x22, 0x26),
        ripple: RGBA(0x9e, 0x98, 0x8e), pellet: RGBA(0xc8, 0x70, 0x26), ink: RGBA(0x25, 0x24, 0x2c),
        text: RGBA(0x8e, 0x88, 0x7e),
        whale: RGBA(0x5f, 0x70, 0x86), whaleLight: RGBA(0xa4, 0xb2, 0xc2),
        turtleShell: RGBA(0x77, 0x82, 0x45), turtleShellDark: RGBA(0x52, 0x5a, 0x2e), turtleSkin: RGBA(0x9a, 0xa4, 0x74),
        squid: RGBA(0xc6, 0x8a, 0x82, 230), squidSpot: RGBA(0x8e, 0x45, 0x3d),
        shrimp: RGBA(0xe0, 0x96, 0x80, 230),
        leaf: RGBA(0x5b, 0x8f, 0x4c), leafDark: RGBA(0x3f, 0x6c, 0x36), leafVein: RGBA(0x8c, 0xb8, 0x70),
        petal: RGBA(0xe8, 0x8e, 0xaa), stamen: RGBA(0xe6, 0xb8, 0x3e)
    )

    public static func make(_ g: GlobalSettings) -> Palette {
        var p = g.theme == .dark ? Palette.dark : Palette.light
        if let bg = RGBA(hex: g.backgroundHex) {
            p.background = bg
            // keep shadows a step away from a custom background
            let lum = 0.299 * Double(bg.r) + 0.587 * Double(bg.g) + 0.114 * Double(bg.b)
            p.shadow = lum < 128 ? bg.mixed(with: RGBA(255, 255, 255), 0.07) : bg.mixed(with: RGBA(0, 0, 0), 0.08)
        }
        return p
    }

    /// A colour seen through `depth` of water (0 surface … 1 deep).
    @inlinable public func submerged(_ c: RGBA, _ depth: Double) -> RGBA {
        c.mixed(with: background.alpha(Double(c.a) / 255), clamp(depth, 0, 1) * 0.72)
    }
}
