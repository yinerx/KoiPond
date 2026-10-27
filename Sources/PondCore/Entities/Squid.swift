import Foundation

/// A squid: mantle first, it moves in jets — a quick squeeze, a burst, a glide. Startled, it inks and dashes off.
public final class Squid: Creature, Relocatable {
    public let kind = EntityKind.squid
    public let groupID: UUID
    let size: Double
    var pos: Vec2              // centre of the head (where the arms start)
    var vel = Vec2.zero
    var heading: Double        // direction of travel = direction the mantle tip points
    var wander: Double = 0
    var squeeze: Double = 0    // 0…1 mantle contraction
    var nextJet: Double
    var inkReady: Double = 0
    public var depth: Double
    var arms: [Strand] = []
    let spots: [(Double, Double)]
    public var position: Vec2 { pos }
    var length: Double { EntityKind.squid.baseLength * size }

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        groupID = g.id
        self.size = size
        pos = p
        heading = w.rng.angle()
        depth = w.rng.range(g.depthMin, g.depthMax)
        nextJet = w.time + w.rng.range(0.5, 2)
        let L = EntityKind.squid.baseLength * size
        for i in 0..<10 { arms.append(Strand(at: p, count: i >= 8 ? 9 : 6, spacing: L * (i >= 8 ? 0.07 : 0.055))) }
        spots = (0..<9).map { _ in (w.rng.range(0.15, 0.9), w.rng.range(-0.7, 0.7)) }
    }

    func relocate(scaleX: Double, scaleY: Double) {
        let np = Vec2(pos.x * scaleX, pos.y * scaleY), d = np - pos
        pos = np; for i in arms.indices { arms[i].translate(d) }
    }

    public func startle(_ w: World, at p: Vec2, amount: Double) {
        guard p.distance(to: pos) < length * 1.6 + 60, let g = w.group(groupID) else { return }
        heading = (pos - p).angle
        jet(w, power: 1.6 + amount)
        if g.params.inkEnabled && w.time > inkReady {
            inkReady = w.time + 6
            let back = -Vec2.polar(heading)
            for _ in 0..<40 {
                let a = back.angle + w.rng.range(-0.9, 0.9), s = w.rng.range(10, 70)
                w.emit(.ink, at: pos + back * (length * 0.1), vel: Vec2.polar(a, s), life: w.rng.range(2, 4.5),
                       glyph: [UInt8(ascii: "%"), UInt8(ascii: "@"), UInt8(ascii: "&"), UInt8(ascii: "*")][w.rng.int(0, 3)])
            }
        }
    }
    public func feelRipple(_ w: World, from p: Vec2, strength: Double) {
        if strength > 0.35 { startle(w, at: p, amount: strength * 0.5) }
    }

    func jet(_ w: World, power: Double) {
        squeeze = 1
        vel += Vec2.polar(heading) * (110 * power * size.squareRoot())
    }

    public func step(_ w: World, _ dt: Double) {
        guard let g = w.group(groupID) else { return }
        wander = clamp(wander + w.rng.range(-1, 1) * dt * 1.8, -0.8, 0.8)
        var want = Vec2.polar(heading + wander)
        let m = length + 40
        if pos.x < m { want.x += 1.5 }; if pos.x > w.width - m { want.x -= 1.5 }
        if pos.y < m { want.y += 1.5 }; if pos.y > w.height - m { want.y -= 1.5 }
        // it only turns while gliding slowly
        let slow = 1 - min(1, vel.length / 120)
        heading = turn(heading, toward: want.angle, maxStep: (0.4 + 1.6 * slow) * dt)
        if w.time > nextJet {
            jet(w, power: g.speed)
            nextJet = w.time + w.rng.range(0.7, 1.3) / max(0.05, g.params.jetRate * g.speed)
        }
        squeeze = max(0, squeeze - dt * 2.5)
        vel *= exp(-1.6 * dt)
        pos += vel * dt
        depth += (clamp(depth, g.depthMin, g.depthMax) - depth) * dt
        let back = -Vec2.polar(heading)
        for i in arms.indices {
            let spread = i >= 8 ? (i == 8 ? -0.25 : 0.25) : (Double(i) / 7 - 0.5) * 1.1
            let anchor = pos + back.rotated(spread) * (length * 0.06)
            arms[i].follow(anchor, drift: back, sway: sin(w.time * 2.3 + Double(i) * 0.8) * length * 0.04, dt: dt)
        }
    }

    public func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette, z = Float(1 - depth)
        let skin = pal.submerged(pal.squid, depth), spot = pal.submerged(pal.squidSpot, depth)
        let fwd = Vec2.polar(heading), side = fwd.perp
        // arms
        for (i, a) in arms.enumerated() {
            for (k, p) in a.nodes.enumerated() where k > 0 {
                let d = a.nodes[k] - a.nodes[k - 1]
                let glyph = (i >= 8 && k == a.nodes.count - 1) ? UInt8(ascii: "*") : Glyph.line(angle: d.angle)
                g.put(p, glyph: glyph, fg: skin.alpha(1 - Double(k) / Double(a.nodes.count) * 0.4), z: z - 0.002)
            }
        }
        // mantle: a tapered tube from the head forward to the tip, thinner while squeezing
        let L = length, mantleLen = L * 0.55
        let halfW = L * 0.11 * (1 - 0.25 * squeeze)
        let tip = pos + fwd * mantleLen
        let lo = Vec2(min(pos.x, tip.x), min(pos.y, tip.y)) - Vec2(halfW * 2, halfW * 2)
        let hi = Vec2(max(pos.x, tip.x), max(pos.y, tip.y)) + Vec2(halfW * 2, halfW * 2)
        let (c0, r0) = g.cellOf(lo), (c1, r1) = g.cellOf(hi)
        guard let span = g.clip(cols: c0, c1, rows: r0, r1) else { return }
        for row in span.rows {
            for col in span.cols {
                let d = g.center(col, row) - pos
                let s = d.dot(fwd) / mantleLen, v = d.dot(side)
                guard s >= -0.12, s <= 1.05 else { continue }
                // width: round head, full mantle, pointed tip with fins
                var w0 = halfW * (s < 0 ? 0.8 : (1 - pow(max(0, s - 0.35) / 0.7, 1.6)))
                let fin = s > 0.72 ? halfW * 0.9 * sin((s - 0.72) / 0.33 * .pi) : 0
                w0 = max(w0, 0)
                let a = abs(v)
                if a <= w0 {
                    var tile = skin
                    for (ss, vv) in spots where abs(s - ss) < 0.07 && abs(v / max(1, w0) - vv) < 0.3 { tile = spot }
                    // chromatophores flicker
                    if hash01(col, row, Int(w.time * 3)) > 0.93 { tile = spot }
                    let glyph: UInt8 = s < 0 ? UInt8(ascii: "o") : (a > w0 * 0.7 ? Glyph.line(angle: heading) : UInt8(ascii: ":"))
                    g.put(col, row, glyph: glyph, fg: tile.mixed(with: pal.background, 0.3), bg: tile.alpha(0.55), z: z)
                } else if a <= w0 + fin {
                    g.put(col, row, glyph: v > 0 ? UInt8(ascii: ">") : UInt8(ascii: "<"), fg: skin, z: z - 0.001)
                }
            }
        }
        // eyes on the head
        for k in [-1.0, 1.0] { g.put(pos + side * (k * halfW * 0.9) - fwd * (L * 0.02), glyph: UInt8(ascii: "o"), fg: pal.submerged(pal.eye, depth), z: z + 0.002) }
    }
}
