import Foundation

/// Duckweed: a drifting cluster of tiny round leaves on the surface. Ripples push it; clusters keep apart.
public final class Duckweed: Creature, Relocatable {
    struct Leaf { var off: Vec2; var big: Bool; var shade: Double }
    public let kind = EntityKind.duckweed
    public let groupID: UUID
    let size: Double
    var pos: Vec2
    var vel = Vec2.zero
    var leaves: [Leaf] = []
    var spread: Double = 1
    public var depth: Double { 0 }
    public var position: Vec2 { pos }
    var radius: Double { EntityKind.duckweed.baseLength * 0.5 * size }

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        groupID = g.id
        self.size = size
        pos = p
        let r = EntityKind.duckweed.baseLength * 0.5 * size
        for _ in 0..<max(3, Int(Double(g.params.clusterSize) * size)) {
            let a = w.rng.angle(), d = r * w.rng.unit().squareRoot()
            leaves.append(Leaf(off: Vec2(cos(a) * d, sin(a) * d * 0.8), big: w.rng.chance(0.3), shade: w.rng.unit()))
        }
        vel = Vec2.polar(w.rng.angle(), 3)
    }

    func relocate(scaleX: Double, scaleY: Double) { pos = Vec2(pos.x * scaleX, pos.y * scaleY) }

    public func feelRipple(_ w: World, from p: Vec2, strength: Double) {
        vel += (pos - p).normalized * (22 * strength / max(0.5, size))
        spread = min(1.6, spread + strength * 0.4)
    }

    public func step(_ w: World, _ dt: Double) {
        guard w.group(groupID) != nil else { return }
        // a faint current, plus keep apart from other clusters
        vel += Vec2(sin(w.time * 0.07 + pos.y * 0.01), cos(w.time * 0.05 + pos.x * 0.01)) * (1.2 * dt)
        for o in w.creatures where o !== self && o.kind == .duckweed {
            let d = pos - o.position, l = d.length
            if l < radius * 2 && l > 0 { vel += d.normalized * (radius * 2 - l) * 0.4 * dt }
        }
        vel *= exp(-0.5 * dt)
        pos += vel * dt
        spread += (1 - spread) * dt * 0.3
        // drift back in from the edges
        let m = radius
        if pos.x < m { vel.x += 4 * dt }; if pos.x > w.width - m { vel.x -= 4 * dt }
        if pos.y < m { vel.y += 4 * dt }; if pos.y > w.height - m { vel.y -= 4 * dt }
    }

    public func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette
        for (i, l) in leaves.enumerated() {
            let bob = Vec2(sin(w.time * 0.8 + Double(i)), cos(w.time * 0.6 + Double(i) * 1.3)) * 1.5
            let p = pos + l.off * spread + bob
            let col = l.shade < 0.5 ? pal.leaf : pal.leafVein
            g.put(p, glyph: l.big ? UInt8(ascii: "O") : (l.shade > 0.8 ? Glyph.degree : UInt8(ascii: "o")), fg: col, bg: pal.leafDark.alpha(0.45), z: 2)
        }
    }
}

/// Water lily: anchored pads (a disc with a notch and veins), some with a flower. Ripples rock them; a spring brings them back.
public final class WaterLily: Creature, Relocatable {
    struct Pad { var off: Vec2; var r: Double; var rot: Double }
    public let kind = EntityKind.waterLily
    public let groupID: UUID
    let size: Double
    var anchor: Vec2
    var disp = Vec2.zero
    var vel = Vec2.zero
    var pads: [Pad] = []
    let flower: Bool
    let flowerPad: Int
    public var depth: Double { 0 }
    public var position: Vec2 { anchor + disp }

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        groupID = g.id
        self.size = size
        anchor = p
        let R = EntityKind.waterLily.baseLength * 0.5 * size
        let n = w.rng.int(1, 3)
        for i in 0..<n {
            let off = i == 0 ? Vec2.zero : Vec2.polar(w.rng.angle(), R * w.rng.range(1.1, 1.6))
            pads.append(Pad(off: off, r: R * (i == 0 ? 1 : w.rng.range(0.5, 0.8)), rot: w.rng.angle()))
        }
        flower = w.rng.chance(g.params.flowerChance)
        flowerPad = 0
    }

    func relocate(scaleX: Double, scaleY: Double) { anchor = Vec2(anchor.x * scaleX, anchor.y * scaleY) }

    public func feelRipple(_ w: World, from p: Vec2, strength: Double) {
        vel += (position - p).normalized * (30 * strength / max(0.5, size))
    }

    public func step(_ w: World, _ dt: Double) {
        guard w.group(groupID) != nil else { return }
        // spring back to the anchor (the stem holds it), damped
        vel += (-disp * 1.5) * dt
        vel *= exp(-1.2 * dt)
        disp += vel * dt
        for i in pads.indices { pads[i].rot += sin(w.time * 0.3 + Double(i)) * 0.02 * dt + vel.x * 0.0004 }
    }

    public func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette
        let base = position
        for (pi, pad) in pads.enumerated() {
            let c = base + pad.off
            let R = pad.r
            let (c0, r0) = g.cellOf(c - Vec2(R, R)), (c1, r1) = g.cellOf(c + Vec2(R, R))
            guard let span = g.clip(cols: c0, c1, rows: r0, r1) else { continue }
            for row in span.rows {
                for col in span.cols {
                    let d = g.center(col, row) - c
                    let dist = (Vec2(d.x, d.y / 0.85)).length
                    guard dist <= R else { continue }
                    let ang = wrapAngle(atan2(d.y / 0.85, d.x) - pad.rot)
                    if abs(ang) < 0.22 { continue }                       // the notch
                    let edge = dist > R * 0.82
                    let vein = abs(sin(ang * 4)) < 0.18 && dist > R * 0.15
                    let tile = edge ? pal.leafDark : pal.leaf
                    let glyph: UInt8 = vein ? Glyph.line(angle: ang + pad.rot) : (edge ? UInt8(ascii: "~") : Glyph.space)
                    g.put(col, row, glyph: glyph, fg: pal.leafVein, bg: tile, z: 2 + Float(pi) * 0.01)
                }
            }
        }
        guard flower else { return }
        // flower: two rings of petals around a golden centre, drawn above the pad
        let c = base + pads[flowerPad].off
        let fr = pads[flowerPad].r * 0.42
        for k in 0..<8 {
            let a = Double(k) / 8 * 2 * .pi + w.time * 0.05
            g.put(c + Vec2(cos(a) * fr, sin(a) * fr * 0.85), glyph: UInt8(ascii: "*"), fg: pal.petal, bg: pal.petal.mixed(with: pal.leafDark, 0.55), z: 2.2)
            let b = a + .pi / 8
            g.put(c + Vec2(cos(b) * fr * 0.55, sin(b) * fr * 0.5), glyph: UInt8(ascii: "v"), fg: pal.petal, z: 2.21)
        }
        g.put(c, glyph: UInt8(ascii: "@"), fg: pal.stamen, bg: pal.stamen.mixed(with: pal.leafDark, 0.6), z: 2.22)
    }
}
