import Foundation

/// A turtle: a plated shell, a head, four flippers paddling in turn. Slow; now and then it surfaces for air.
public final class Turtle: Creature, Relocatable {
    public let kind = EntityKind.turtle
    public let groupID: UUID
    let size: Double
    var pos: Vec2
    var heading: Double
    var wander: Double = 0
    var speed: Double = 0
    var paddle: Double
    public var depth: Double
    var targetDepth: Double
    var nextSurface: Double
    var fear: Double = 0
    var fearFrom = Vec2.zero
    public var position: Vec2 { pos }
    var length: Double { EntityKind.turtle.baseLength * size }

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        groupID = g.id
        self.size = size
        pos = p
        heading = w.rng.angle()
        paddle = w.rng.angle()
        depth = w.rng.range(g.depthMin, g.depthMax)
        targetDepth = depth
        nextSurface = w.time + w.rng.range(5, g.params.surfaceInterval)
    }

    func relocate(scaleX: Double, scaleY: Double) { pos = Vec2(pos.x * scaleX, pos.y * scaleY) }

    public func startle(_ w: World, at p: Vec2, amount: Double) {
        if p.distance(to: pos) < length * 1.4 { fear = max(fear, amount); fearFrom = p; targetDepth = 1 }
    }

    public func step(_ w: World, _ dt: Double) {
        guard let g = w.group(groupID) else { return }
        wander = clamp(wander + w.rng.range(-1, 1) * dt * 1.2, -0.7, 0.7)
        var v = Vec2.polar(heading + wander)
        let m = length + 30
        if pos.x < m { v.x += 1.5 }; if pos.x > w.width - m { v.x -= 1.5 }
        if pos.y < m { v.y += 1.5 }; if pos.y > w.height - m { v.y -= 1.5 }
        if fear > 0.05 { v += (pos - fearFrom).normalized * fear * 2 }
        heading = turn(heading, toward: v.angle, maxStep: 0.7 * dt)
        speed = lerp(speed, 16 * size.squareRoot() * g.speed * (1 + fear * 1.5), 1 - exp(-1.5 * dt))
        paddle += dt * (1.6 + speed / 20)
        // strokes come in pulses: faster during the power stroke
        let stroke = 0.6 + 0.6 * max(0, sin(paddle))
        pos += Vec2.polar(heading) * speed * stroke * dt
        fear = max(0, fear - 0.4 * dt)
        if w.time > nextSurface {
            targetDepth = 0
            if depth < 0.06 {
                let nose = pos + Vec2.polar(heading) * (length * 0.45)
                for _ in 0..<5 { w.emit(.bubble, at: nose, vel: Vec2(w.rng.range(-12, 12), w.rng.range(-12, 12)), life: w.rng.range(0.8, 1.6), glyph: [UInt8(ascii: "o"), Glyph.degree][w.rng.int(0, 1)]) }
                w.addRipple(at: nose, strength: 0.35, speed: 50)
                nextSurface = w.time + g.params.surfaceInterval * w.rng.range(0.7, 1.3)
                targetDepth = w.rng.range(g.depthMin, g.depthMax)
            }
        }
        targetDepth = clamp(targetDepth, 0, 1)
        depth += (targetDepth - depth) * (1 - exp(-0.6 * dt))
    }

    public func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette, z = Float(1 - depth)
        let shell = pal.submerged(pal.turtleShell, depth), dark = pal.submerged(pal.turtleShellDark, depth)
        let skin = pal.submerged(pal.turtleSkin, depth)
        let fwd = Vec2.polar(heading), side = fwd.perp, L = length
        let a = L * 0.3, b = L * 0.24
        // flippers: front pair big and sweeping, back pair small, opposite phase
        for (s, len, ph) in [(0.55, 0.32, 0.0), (-0.6, 0.16, Double.pi)] {
            for k in [-1.0, 1.0] {
                let root = pos + fwd * (a * s) + side * (k * b * 0.85)
                let sweep = 0.6 + sin(paddle + ph) * 0.55
                let dir = (side * k * cos(sweep) - fwd * sin(sweep)).normalized
                g.line(root, root + dir * (L * len), fg: skin, z: z - 0.002)
                g.line(root + fwd * 3, root + dir * (L * len * 0.85) + fwd * 3, fg: skin, z: z - 0.002)
            }
        }
        // tail and head
        g.line(pos - fwd * a, pos - fwd * (a + L * 0.1), fg: skin, z: z - 0.002)
        let headC = pos + fwd * (a + L * 0.1)
        let (hc, hr) = g.cellOf(headC)
        for dr in -1...1 { for dc in -1...1 where abs(dr) + abs(dc) <= 1 { g.put(hc + dc, hr + dr, glyph: UInt8(ascii: "@"), fg: skin.mixed(with: pal.background, 0.3), bg: skin, z: z) } }
        for k in [-1.0, 1.0] { g.put(headC + side * (k * g.cellSize * 0.7) + fwd * 3, glyph: UInt8(ascii: "o"), fg: pal.submerged(pal.eye, depth), z: z + 0.002) }
        // shell: an ellipse with a plate pattern (hexagon-ish cells, darker seams)
        let shadows = w.config.global.shadows && depth < 0.5
        let pad = shadows ? g.cellSize * 0.9 : 0
        let (c0, r0) = g.cellOf(pos - Vec2(a + pad + 4, a + pad + 4)), (c1, r1) = g.cellOf(pos + Vec2(a + pad + 4, a + pad + 4))
        guard r0 <= r1, c0 <= c1 else { return }
        for row in max(0, r0)...max(0, min(g.rows - 1, r1)) {
            for col in max(0, c0)...max(0, min(g.cols - 1, c1)) {
                let d = g.center(col, row) - pos
                let u = d.dot(fwd), v = d.dot(side)
                let q = (u / a) * (u / a) + (v / b) * (v / b)
                if q > 1 {
                    let qs = (u / (a + pad)) * (u / (a + pad)) + (v / (b + pad)) * (v / (b + pad))
                    if pad > 0 && qs <= 1 { g.tint(col, row, bg: pal.shadow.alpha(1 - depth * 0.8), z: z - 0.01) }
                    continue
                }
                // plates: rings around the centre plus spokes
                let ring = Int((q.squareRoot() * 3).rounded(.down)), ang = atan2(v / b, u / a)
                let spoke = Int(((ang + .pi) / (2 * .pi) * Double(5 + ring * 3)).rounded(.down))
                let seam = abs((q.squareRoot() * 3).truncatingRemainder(dividingBy: 1) - 0.5) > 0.38
                let tile = q > 0.8 ? dark : ((ring + spoke) % 2 == 0 ? shell : shell.mixed(with: dark, 0.35))
                let glyph: UInt8 = seam ? UInt8(ascii: "#") : (q > 0.8 ? UInt8(ascii: "=") : UInt8(ascii: "O"))
                g.put(col, row, glyph: glyph, fg: tile.mixed(with: pal.background, 0.4), bg: tile, z: z)
            }
        }
    }
}
