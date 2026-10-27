import Foundation

/// A soft trailing strand: each node eases toward a fixed distance behind the previous one.
struct Strand {
    var nodes: [Vec2]
    let spacing: Double
    init(at p: Vec2, count: Int, spacing: Double) { nodes = Array(repeating: p, count: count); self.spacing = spacing }
    mutating func follow(_ anchor: Vec2, drift: Vec2, sway: Double, dt: Double) {
        nodes[0] = anchor
        for i in 1..<nodes.count {
            let d = nodes[i] - nodes[i - 1]
            var target = nodes[i - 1] + d.normalized * spacing
            target += drift.perp.normalized * (sway * Double(i) / Double(nodes.count))
            nodes[i] = nodes[i] + (target - nodes[i]) * min(1, 18 * dt)
            // never stretch beyond the rest length
            let e = nodes[i] - nodes[i - 1]
            if e.length > spacing * 1.15 { nodes[i] = nodes[i - 1] + e.normalized * spacing * 1.15 }
        }
    }
    mutating func translate(_ v: Vec2) { for i in nodes.indices { nodes[i] += v } }
}

/// A jellyfish: the bell pulses — contracting pushes it forward — tentacles trail behind. Ripples nudge it.
public final class Jellyfish: Creature, Relocatable {
    public let kind = EntityKind.jellyfish
    public let groupID: UUID
    let size: Double
    var pos: Vec2
    var vel = Vec2.zero
    var heading: Double
    var pulse: Double
    public var depth: Double
    var tentacles: [Strand] = []
    let hue: RGBA
    public var position: Vec2 { pos }
    var radius: Double { EntityKind.jellyfish.baseLength * 0.36 * size }

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        groupID = g.id
        self.size = size
        pos = p
        heading = w.rng.angle()
        pulse = w.rng.unit()
        depth = w.rng.range(g.depthMin, g.depthMax)
        hue = RGBA(hex: g.params.hue) ?? RGBA(0xd9, 0xa3, 0xe8)
        let r = EntityKind.jellyfish.baseLength * 0.36 * size
        let n = 7
        for _ in 0..<n { tentacles.append(Strand(at: p, count: 9, spacing: r * 0.32 * g.params.tentacleLength)) }
    }

    func relocate(scaleX: Double, scaleY: Double) {
        let np = Vec2(pos.x * scaleX, pos.y * scaleY), d = np - pos
        pos = np; for i in tentacles.indices { tentacles[i].translate(d) }
    }

    /// 0 = relaxed, 1 = fully contracted.
    var contraction: Double {
        let f = pulse.truncatingRemainder(dividingBy: 1)
        return f < 0.22 ? sin(f / 0.22 * .pi / 2) : 1 - smoothstep(0.22, 0.8, f)
    }

    public func feelRipple(_ w: World, from p: Vec2, strength: Double) {
        vel += (pos - p).normalized * (28 * strength / max(0.5, size))
    }

    public func step(_ w: World, _ dt: Double) {
        guard let g = w.group(groupID) else { return }
        let prev = pulse.truncatingRemainder(dividingBy: 1)
        pulse += dt * g.params.pulseRate * g.speed * (0.8 + 0.4 / size)
        let f = pulse.truncatingRemainder(dividingBy: 1)
        if f < 0.22 || f < prev { vel += Vec2.polar(heading) * (60 * dt / 0.22 * g.speed) }
        // drift: turn slowly, steer back from the edges
        heading += w.rng.range(-1, 1) * dt * 0.6
        let m = radius * 2 + 30
        var back = Vec2.zero
        if pos.x < m { back.x += 1 }; if pos.x > w.width - m { back.x -= 1 }
        if pos.y < m { back.y += 1 }; if pos.y > w.height - m { back.y -= 1 }
        if back != .zero { heading = turn(heading, toward: back.angle, maxStep: 1.2 * dt) }
        vel *= exp(-1.3 * dt)
        pos += vel * dt
        depth += (clamp(depth, g.depthMin, g.depthMax) - depth) * dt
        // tentacles hang from the trailing half of the rim
        let r = radius * (1 - 0.25 * contraction)
        let backDir = -Vec2.polar(heading)
        for i in tentacles.indices {
            let a = (Double(i) / Double(tentacles.count - 1) - 0.5) * 2.2
            let anchor = pos + backDir.rotated(a) * (r * 0.85)
            tentacles[i].follow(anchor, drift: backDir, sway: sin(w.time * 1.7 + Double(i)) * radius * 0.25, dt: dt)
        }
    }

    public func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette, z = Float(1 - depth)
        let op = w.group(groupID)?.params.opacity ?? 0.7
        let body = pal.submerged(hue, depth).alpha(op)
        let rim = pal.submerged(hue.mixed(with: RGBA(255, 255, 255), 0.35), depth).alpha(min(1, op + 0.2))
        // tentacles behind the bell
        for t in tentacles {
            for (i, p) in t.nodes.enumerated() where i > 0 {
                let glyph: UInt8 = i % 3 == 0 ? Glyph.middleDot : (i % 3 == 1 ? UInt8(ascii: ":") : UInt8(ascii: "."))
                g.put(p, glyph: glyph, fg: body.alpha(1 - Double(i) / Double(t.nodes.count) * 0.6), z: z - 0.002)
            }
        }
        // bell: an ellipse squeezed along the heading while contracting
        let c = contraction, r = radius
        let ax = r * (1 - 0.22 * c), ay = r * (1 + 0.08 * c)
        let fwd = Vec2.polar(heading), side = fwd.perp
        let (c0, r0) = g.cellOf(pos - Vec2(r * 1.2, r * 1.2)), (c1, r1) = g.cellOf(pos + Vec2(r * 1.2, r * 1.2))
        guard let span = g.clip(cols: c0, c1, rows: r0, r1) else { return }
        for row in span.rows {
            for col in span.cols {
                let d = g.center(col, row) - pos
                let u = d.dot(fwd) / ax, v = d.dot(side) / ay
                let q = u * u + v * v
                guard q <= 1 else { continue }
                let glyph: UInt8
                let fg: RGBA
                if q > 0.62 { glyph = Glyph.line(angle: atan2(d.y, d.x) + .pi / 2); fg = rim }
                else if q < 0.12 { glyph = UInt8(ascii: "%"); fg = rim }          // gonads, the bright centre
                else { glyph = hash01(col, row) < 0.5 ? UInt8(ascii: ":") : Glyph.middleDot; fg = body }
                g.put(col, row, glyph: glyph, fg: fg, bg: body.alpha(q > 0.62 ? 0.42 : 0.3), z: z)
            }
        }
    }
}
