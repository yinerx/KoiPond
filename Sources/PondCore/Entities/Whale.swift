import Foundation

/// A whale: long, slow, mostly deep. Every so often it rises, blows a spout and leaves a big ripple.
public final class Whale: SpineSwimmer {
    var nextSpout: Double
    var surfacing = false

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        nextSpout = w.time + w.rng.range(4, g.params.spoutInterval)
        super.init(kind: .whale, group: g, size: size, at: p, world: w, nodes: 22)
        cruise = 40; turnRate = 0.4; turnRadius = 0.55; wiggle = 0.05; wiggleRate = 1.0
        edgeMargin = 160; offscreenAllowance = length * 0.25
    }

    func width(_ s: Double) -> Double {
        let maxW = length * 0.1
        if s < 0.12 { return maxW * (0.55 + 0.45 * (s / 0.12).squareRoot()) }
        return maxW * (0.06 + 0.94 * pow(1 - smoothstep(0.2, 1.0, s), 1.4))
    }

    override func afterStep(_ w: World, _ g: EntityGroup, _ dt: Double) {
        if !surfacing && w.time > nextSpout { surfacing = true }
        if surfacing {
            targetDepth = 0
            if depth < 0.08 {
                // blow: spray up and outward from the blowhole, one big slow ripple
                let hole = spine.point(at: 0.12)
                for _ in 0..<26 {
                    let a = w.rng.angle(), sp = w.rng.range(20, 90)
                    w.emit(.spray, at: hole, vel: Vec2(cos(a) * sp * 0.6, sin(a) * sp * 0.4 - 50), life: w.rng.range(0.6, 1.4),
                           glyph: [UInt8(ascii: "'"), UInt8(ascii: "."), UInt8(ascii: "*"), Glyph.degree][w.rng.int(0, 3)])
                }
                w.addRipple(at: hole, strength: 1.0, speed: 60)
                surfacing = false
                nextSpout = w.time + g.params.spoutInterval * w.rng.range(0.7, 1.3)
                nextDepthChange = w.time + w.rng.range(3, 6)
            }
        }
    }

    public override func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette, z = self.z, fade = depth
        let back = pal.submerged(pal.whale, fade), light = pal.submerged(pal.whaleLight, fade)
        let edge = pal.submerged(pal.whale.mixed(with: pal.background, 0.35), fade)
        let L = length
        // flippers and flukes
        let fin = pal.submerged(pal.whale.mixed(with: pal.whaleLight, 0.3), fade)
        let f = spine.forward(atS: 0.32), base = spine.point(at: 0.32)
        let beat = sin(phase * 0.7) * 0.2
        for k in [-1.0, 1.0] {
            let root = base + f.perp * (k * width(0.32) * 0.85)
            let dir = (f.perp * k * cos(0.75 + beat) - f * sin(0.75 + beat)).normalized
            for t in [0.0, 0.5] {
                let off = f * (-t * L * 0.025)
                g.line(root + off, root + off + dir * (L * 0.13 * (1 - t * 0.3)), fg: fin, z: z - 0.001)
            }
        }
        let tf = spine.forward(at: spine.nodes.count - 1), tail = spine.tail
        let flex = sin(phase - 1) * 0.25
        for k in [-1.0, 1.0] {
            let dir = (tf.perp * k - tf * 0.45).normalized.rotated(flex * k)
            g.line(tail, tail + dir * (L * 0.15), fg: fin, z: z - 0.001)
            g.line(tail - tf * (L * 0.02), tail + dir * (L * 0.12) - tf * (L * 0.03), fg: fin, z: z - 0.001)
        }
        let shadows = w.config.global.shadows && depth < 0.5
        spine.rasterize(g, pad: shadows ? g.cellSize : 0, maxWidth: L * 0.1, width: width) { c, r, s, v, inside in
            if !inside { g.tint(c, r, bg: pal.shadow.alpha(1 - fade * 0.8), z: z - 0.01); return }
            let h = hash01(c, r, 3)
            let tile = abs(v) > 0.78 ? edge : back
            var glyph: UInt8 = h < 0.5 ? UInt8(ascii: "=") : h < 0.75 ? UInt8(ascii: "#") : Glyph.space
            var fg = tile.mixed(with: pal.background, 0.4)
            if h > 0.93 { glyph = UInt8(ascii: "."); fg = light }   // barnacle speckle
            if s < 0.05 { glyph = UInt8(ascii: "("); }
            g.put(c, r, glyph: glyph, fg: fg, bg: tile, z: z)
        }
        // eyes and blowhole
        let fh = spine.forward(atS: 0.1)
        for k in [-1.0, 1.0] { g.put(spine.point(at: 0.09) + fh.perp * (k * width(0.09) * 0.8), glyph: UInt8(ascii: "o"), fg: light, z: z + 0.002) }
        g.put(spine.point(at: 0.13), glyph: UInt8(ascii: "\""), fg: light, z: z + 0.002)
    }
}
