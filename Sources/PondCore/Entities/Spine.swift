import Foundation

/// A chain of nodes: the head leads, every node keeps a fixed distance to the one before it,
/// and no joint bends more than `maxBend`. Swimming comes from wiggling the head's path.
public struct Spine: Sendable {
    public var nodes: [Vec2]
    public let spacing: Double
    public var maxBend: Double

    public init(head: Vec2, heading: Double, count: Int, length: Double, maxBend: Double = 0.2) {
        let sp = length / Double(max(1, count - 1))
        spacing = sp
        self.maxBend = maxBend
        nodes = (0..<count).map { head - Vec2.polar(heading, sp * Double($0)) }
    }

    public var head: Vec2 { nodes[0] }
    public var tail: Vec2 { nodes[nodes.count - 1] }
    public var length: Double { spacing * Double(nodes.count - 1) }

    public mutating func follow(_ newHead: Vec2) {
        nodes[0] = newHead
        for i in 1..<nodes.count {
            var dir = (nodes[i] - nodes[i - 1]).normalized
            if i >= 2 {
                // keep the joint from folding: clamp against the previous segment's direction
                let prev = (nodes[i - 1] - nodes[i - 2]).normalized
                let a = wrapAngle(dir.angle - prev.angle)
                if abs(a) > maxBend { dir = Vec2.polar(prev.angle + (a > 0 ? maxBend : -maxBend)) }
            }
            nodes[i] = nodes[i - 1] + dir * spacing
        }
    }

    public mutating func scale(x sx: Double, y sy: Double) {
        let h = nodes[0], nh = Vec2(h.x * sx, h.y * sy)
        for i in nodes.indices { nodes[i] = nodes[i] - h + nh }
    }

    /// Direction from node i toward the head.
    public func forward(at i: Int) -> Vec2 {
        let a = max(0, i - 1), b = min(nodes.count - 1, i + 1)
        return (nodes[a] - nodes[b]).normalized
    }

    /// Point along the spine at s ∈ [0, 1] (0 = head).
    public func point(at s: Double) -> Vec2 {
        let f = clamp(s, 0, 1) * Double(nodes.count - 1)
        let i = min(nodes.count - 2, Int(f)), t = f - Double(i)
        return nodes[i] + (nodes[i + 1] - nodes[i]) * t
    }
    public func forward(atS s: Double) -> Vec2 { forward(at: Int((clamp(s, 0, 1) * Double(nodes.count - 1)).rounded())) }

    /// Nearest spine position to p: s ∈ [0, 1] and signed lateral distance (+ = left of the swimming direction).
    public func project(_ p: Vec2) -> (s: Double, lateral: Double, dist2: Double) {
        var best = (s: 0.0, lateral: 0.0, dist2: Double.greatestFiniteMagnitude)
        let n = nodes.count - 1
        for i in 0..<n {
            let a = nodes[i], b = nodes[i + 1], ab = b - a
            let t = clamp((p - a).dot(ab) / max(1e-9, ab.lengthSquared), 0, 1)
            let q = a + ab * t, d2 = (p - q).lengthSquared
            if d2 < best.dist2 {
                // forward is b→a (toward the head); left side is the sign of the cross product
                let side = (a - b).cross(p - q) >= 0 ? 1.0 : -1.0
                best = ((Double(i) + t) / Double(n), side * d2.squareRoot(), d2)
            }
        }
        return best
    }

    /// Calls `body` for every grid cell whose centre lies within `width(s) + pad` of the spine, in row-major order.
    /// `v` is the lateral position relative to the half-width (−1…1 inside the body, beyond for the pad).
    /// `maxWidth` must be at least the largest `width(s)`.
    ///
    /// Each segment only visits the cells near itself and keeps the nearest segment per cell; a cell that is
    /// near no segment is never looked at. That finds the same nearest point as testing every cell of the
    /// bounding box against every segment (ties go to the lower segment, as before) at a fraction of the work:
    /// a long, thin, slanted body fills little of its bounding box.
    public func rasterize(_ g: CellGrid, pad: Double, maxWidth: Double, width: (Double) -> Double,
                          _ body: (_ col: Int, _ row: Int, _ s: Double, _ v: Double, _ inside: Bool) -> Void) {
        let n = nodes.count - 1
        guard n >= 1 else { return }
        // farthest a passing cell centre can be from the spine
        let reach = max(0.5, maxWidth) + pad + 1e-9, reach2 = reach * reach
        var lo = nodes[0], hi = nodes[0]
        for p in nodes { lo = Vec2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vec2(max(hi.x, p.x), max(hi.y, p.y)) }
        let (c0, r0) = g.cellOf(lo - Vec2(reach, reach)), (c1, r1) = g.cellOf(hi + Vec2(reach, reach))
        guard let span = g.clip(cols: c0, c1, rows: r0, r1) else { return }
        let colLo = span.cols.lowerBound, rowLo = span.rows.lowerBound, cols = span.cols.count
        let sc = RasterScratch.shared
        sc.prepare(cols * span.rows.count)

        sc.d2.withUnsafeMutableBufferPointer { d2 in
            sc.s.withUnsafeMutableBufferPointer { sv in
                sc.lat.withUnsafeMutableBufferPointer { lat in
                    for i in 0..<n {
                        let a = nodes[i], b = nodes[i + 1], ab = b - a, len2 = max(1e-9, ab.lengthSquared)
                        let fwd = a - b
                        let (sc0, sr0) = g.cellOf(Vec2(min(a.x, b.x) - reach, min(a.y, b.y) - reach))
                        let (sc1, sr1) = g.cellOf(Vec2(max(a.x, b.x) + reach, max(a.y, b.y) + reach))
                        let ca = max(sc0, span.cols.lowerBound), cb = min(sc1, span.cols.upperBound)
                        let ra = max(sr0, span.rows.lowerBound), rb = min(sr1, span.rows.upperBound)
                        guard ca <= cb, ra <= rb else { continue }
                        for r in ra...rb {
                            let rowBase = (r - rowLo) * cols - colLo
                            for c in ca...cb {
                                let p = g.center(c, r)
                                let t = clamp((p - a).dot(ab) / len2, 0, 1)
                                let q = a + ab * t
                                let dd = (p - q).lengthSquared
                                let k = rowBase + c
                                guard dd <= reach2, dd < d2[k] else { continue }
                                d2[k] = dd
                                sv[k] = (Double(i) + t) / Double(n)
                                lat[k] = (fwd.cross(p - q) >= 0 ? 1.0 : -1.0) * dd.squareRoot()
                            }
                        }
                    }
                }
            }
        }
        for r in span.rows {
            let rowBase = (r - rowLo) * cols - colLo
            for c in span.cols {
                let k = rowBase + c
                guard sc.d2[k] < .infinity else { continue }
                let s = sc.s[k], l = sc.lat[k]
                let w = max(0.5, width(s)), d = abs(l)
                if d <= w + pad { body(c, r, s, l / w, d <= w) }
            }
        }
    }
}

/// Reused scratch buffers for `Spine.rasterize` (drawing happens on one thread).
final class RasterScratch {
    static let shared = RasterScratch()
    var d2: [Double] = [], s: [Double] = [], lat: [Double] = []
    func prepare(_ count: Int) {
        if d2.count < count {
            d2 = Array(repeating: .infinity, count: count)
            s = Array(repeating: 0, count: count)
            lat = Array(repeating: 0, count: count)
        } else {
            d2.withUnsafeMutableBufferPointer { p in for i in 0..<count { p[i] = .infinity } }
        }
    }
}

/// Shared steering for long swimmers (koi, whale): wander, stay in the pond, dive and surface, flee.
public class SpineSwimmer: Creature, Relocatable {
    public let kind: EntityKind
    public let groupID: UUID
    public let size: Double
    public var spine: Spine
    public var heading: Double
    public var speed: Double = 0
    public var wander: Double = 0
    public var phase: Double
    public var depth: Double
    public var targetDepth: Double
    public var nextDepthChange: Double
    public var fear: Double = 0
    public var fearFrom = Vec2.zero
    public var position: Vec2 { spine.head }
    public var length: Double { spine.length }

    // tuning, set by subclasses
    var cruise: Double = 34          // points/s at size 1, speed 1
    var turnRate: Double = 2.0       // rad/s, upper bound
    var turnRadius: Double = 0.4     // smallest turning radius as a fraction of body length
    var wiggle: Double = 0.17        // head path wiggle (rad)
    var wiggleRate: Double = 3.0
    var edgeMargin: Double = 90
    var offscreenAllowance: Double = 0

    init(kind: EntityKind, group g: EntityGroup, size: Double, at p: Vec2, world w: World, nodes: Int) {
        self.kind = kind
        self.groupID = g.id
        self.size = size
        heading = w.rng.angle()
        phase = w.rng.angle()
        depth = w.rng.range(g.depthMin, g.depthMax)
        targetDepth = depth
        nextDepthChange = w.time + w.rng.range(4, 14)
        spine = Spine(head: p, heading: heading, count: nodes, length: kind.baseLength * size)
    }

    func relocate(scaleX: Double, scaleY: Double) { spine.scale(x: scaleX, y: scaleY) }

    public func startle(_ w: World, at p: Vec2, amount: Double) {
        guard let g = w.group(groupID) else { return }
        let sens = kind == .koi ? g.params.startleSensitivity : 0.3
        let d = p.distance(to: spine.head)
        if d < length * 1.2 + 40 { fear = max(fear, amount * sens * 1.6); fearFrom = p }
    }

    /// Desired direction before food; subclasses add their own pulls.
    func steer(_ w: World, _ g: EntityGroup, _ dt: Double) -> Vec2 {
        wander = clamp(wander + w.rng.range(-1, 1) * dt * 2.2, -0.9, 0.9)
        var v = Vec2.polar(heading) + Vec2.polar(heading + wander) * 0.6
        // stay in the pond (bigger animals may drift partly out of view)
        let m = edgeMargin, h = spine.head, out = offscreenAllowance
        if h.x < m - out { v.x += (m - out - h.x) / m * 2.5 }
        if h.x > w.width - m + out { v.x -= (h.x - (w.width - m + out)) / m * 2.5 }
        if h.y < m - out { v.y += (m - out - h.y) / m * 2.5 }
        if h.y > w.height - m + out { v.y -= (h.y - (w.height - m + out)) / m * 2.5 }
        // flee
        if fear > 0.05 { v += (h - fearFrom).normalized * fear * 3 }
        // personal space among the same kind
        for o in w.creatures where o !== self && o.kind == kind {
            let d = o.position - h, l = d.length
            if l < length * 0.5 && l > 0 { v -= d.normalized * (1 - l / (length * 0.5)) * 0.8 }
        }
        return v
    }

    func targetSpeed(_ g: EntityGroup) -> Double { cruise * size.squareRoot() * g.speed * (1 + 2.2 * fear) }

    public func step(_ w: World, _ dt: Double) {
        guard let g = w.group(groupID) else { return }
        let v = steer(w, g, dt)
        let urgency = 1 + fear * 1.5
        let radiusLimited = max(speed, cruise * 0.5) / (length * turnRadius)
        heading = turn(heading, toward: v.angle, maxStep: min(turnRate, radiusLimited) * urgency * dt)
        speed = lerp(speed, targetSpeed(g), 1 - exp(-2.5 * dt))
        phase += dt * (wiggleRate + speed / 18)
        let swim = heading + sin(phase) * wiggle
        spine.follow(spine.head + Vec2.polar(swim, speed * dt))
        fear = max(0, fear - 0.55 * dt)
        // depth: wander between the group's limits
        if w.time > nextDepthChange {
            targetDepth = w.rng.range(g.depthMin, g.depthMax)
            nextDepthChange = w.time + w.rng.range(5, 16)
        }
        targetDepth = clamp(targetDepth, g.depthMin, g.depthMax)
        depth += (targetDepth - depth) * (1 - exp(-0.5 * dt))
        afterStep(w, g, dt)
    }

    func afterStep(_ w: World, _ g: EntityGroup, _ dt: Double) {}
    public func draw(_ w: World, _ g: CellGrid) {}

    /// z for the grid: nearer the surface draws over deeper.
    var z: Float { Float(1 - depth) }
}
