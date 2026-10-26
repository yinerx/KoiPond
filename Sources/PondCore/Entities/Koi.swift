import Foundation

/// A koi: a 16-node spine, a patterned body made of tiles, fins drawn with line glyphs. The only creature that eats.
public final class Koi: SpineSwimmer {
    struct Blob { var s: Double; var v: Double; var rs: Double; var rv: Double; var colour: Int } // colour: 0 red, 1 black, 2 orange
    public let variety: KoiVariety
    let blobs: [Blob]
    let interest: Double          // personal threshold for going after food
    var foodID: Int?
    var gulp: Double = 0
    var finPhase: Double

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        variety = Koi.pickVariety(g.params.varieties, &w.rng)
        interest = w.rng.unit()
        finPhase = w.rng.angle()
        blobs = Koi.pattern(variety, &w.rng)
        super.init(kind: .koi, group: g, size: size, at: p, world: w, nodes: 16)
        cruise = 52; turnRate = 1.6; turnRadius = 0.38; wiggle = 0.13; wiggleRate = 2.4; edgeMargin = 140
    }

    static func pickVariety(_ weights: [String: Double], _ rng: inout PondRandom) -> KoiVariety {
        let pairs = KoiVariety.allCases.map { ($0, max(0, weights[$0.rawValue] ?? 0)) }
        let total = pairs.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return .kohaku }
        var x = rng.unit() * total
        for (v, wgt) in pairs { x -= wgt; if x <= 0 { return v } }
        return .kohaku
    }

    /// Patches in (s, v) body space: s along the body (0 head … 1 tail), v across it (−1 … 1).
    static func pattern(_ v: KoiVariety, _ rng: inout PondRandom) -> [Blob] {
        var b: [Blob] = []
        func red(_ n: Int, from: Double = 0.06, to: Double = 0.78) {
            for _ in 0..<n {
                b.append(Blob(s: rng.range(from, to), v: rng.range(-0.35, 0.35), rs: rng.range(0.07, 0.16), rv: rng.range(0.5, 1.0), colour: 0))
            }
        }
        func black(_ n: Int, big: Bool) {
            for _ in 0..<n {
                b.append(Blob(s: rng.range(0.15, 0.85), v: rng.range(-0.8, 0.8),
                              rs: big ? rng.range(0.07, 0.14) : rng.range(0.025, 0.05),
                              rv: big ? rng.range(0.35, 0.7) : rng.range(0.15, 0.3), colour: 1))
            }
        }
        switch v {
        case .kohaku: red(rng.int(2, 4))
        case .sanke: red(rng.int(2, 3)); black(rng.int(4, 7), big: false)
        case .showa: black(rng.int(3, 5), big: true); red(rng.int(1, 3))
        case .tancho: b.append(Blob(s: 0.1, v: 0, rs: 0.07, rv: 0.55, colour: 0))
        case .asagi:
            b.append(Blob(s: 0.45, v: 1.0, rs: 0.45, rv: 0.35, colour: 2))
            b.append(Blob(s: 0.45, v: -1.0, rs: 0.45, rv: 0.35, colour: 2))
        case .ogon: break
        }
        return b
    }

    /// Half-width along the body.
    func width(_ s: Double) -> Double {
        let L = length, maxW = L * 0.115
        if s < 0.2 { return maxW * (0.45 + 0.55 * (s / 0.2).squareRoot()) }
        return maxW * (0.12 + 0.88 * (1 - smoothstep(0.2, 1.0, s)))
    }

    override func steer(_ w: World, _ g: EntityGroup, _ dt: Double) -> Vec2 {
        var v = super.steer(w, g, dt)
        if g.feedable, let target = food(w, g) {
            let d = target.pos - spine.head
            v = v * 0.25 + d.normalized * 3
            targetDepth = 0
        }
        return v
    }

    override func targetSpeed(_ g: EntityGroup) -> Double {
        var s = super.targetSpeed(g)
        if foodID != nil { s *= 2.1 }
        return s
    }

    /// Keeps the current target unless a much nearer pellet shows up.
    func food(_ w: World, _ g: EntityGroup) -> Pellet? {
        let range = g.params.foodRange * (0.7 + 0.6 * size)
        if interest > g.params.curiosity { foodID = nil; return nil }
        let nearest = w.nearestPellet(to: spine.head, within: range)
        if let id = foodID, let cur = w.pellet(id) {
            let dc = cur.pos.distance(to: spine.head)
            if dc > range * 1.3 { foodID = nearest?.id; return nearest }
            if let n = nearest, n.pos.distance(to: spine.head) < 0.5 * dc { foodID = n.id; return n }
            return cur
        }
        foodID = nearest?.id
        return nearest
    }

    override func afterStep(_ w: World, _ g: EntityGroup, _ dt: Double) {
        gulp = max(0, gulp - dt * 3)
        finPhase += dt * (2.5 + speed / 25)
        guard g.feedable, let id = foodID, let p = w.pellet(id) else { return }
        if p.pos.distance(to: spine.head) < length * 0.07 + 6 {
            if w.eat(id) { gulp = 1 }
            foodID = nil
        }
    }

    // MARK: drawing

    public override func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette, z = self.z, shadows = w.config.global.shadows && depth < 0.55
        let fade = depth
        let base: RGBA = variety == .ogon ? pal.gold : variety == .asagi ? pal.asagi : pal.body
        let edge = pal.submerged(base.mixed(with: pal.bodyEdge, 0.55), fade)
        let bodyCol = pal.submerged(base, fade)
        let marks = [pal.submerged(pal.red, fade), pal.submerged(pal.black, fade), pal.submerged(pal.orange, fade)]
        let textures: [UInt8] = Array("SX%8S$").map { UInt8($0.asciiValue!) }
        let net = UInt8(ascii: "#")
        let maxW = length * 0.115

        // fins first, so the body tiles cover their roots
        drawFins(w, g, pal, z - 0.001, fade)

        spine.rasterize(g, pad: shadows ? g.cellSize * 0.9 : 0, maxWidth: maxW, width: width) { c, r, s, v, inside in
            if !inside {
                g.tint(c, r, bg: pal.shadow.alpha(1 - fade * 0.8), z: z - 0.01)
                return
            }
            var tile = abs(v) > 0.72 ? edge : bodyCol
            for b in blobs {
                let ds = (s - b.s) / b.rs, dv = (v - b.v) / b.rv
                if ds * ds + dv * dv < 1 { tile = marks[b.colour]; break }
            }
            let h = hash01(c, r, Int(s * 7))
            var glyph = variety == .asagi && tile == bodyCol ? net : textures[Int(h * Double(textures.count)) % textures.count]
            if h > 0.86 { glyph = Glyph.space }
            g.put(c, r, glyph: glyph, fg: tile.mixed(with: pal.background, 0.45), bg: tile, z: z)
        }
        // eyes
        let f = spine.forward(atS: 0.06), side = f.perp
        for k in [-1.0, 1.0] {
            let p = spine.point(at: 0.07) + side * (k * width(0.07) * 0.62)
            g.put(p, glyph: UInt8(ascii: "o"), fg: pal.submerged(pal.eye, fade), bg: pal.submerged(pal.bodyEdge, fade), z: z + 0.002)
        }
        if gulp > 0.3 { g.put(spine.head + f * (g.cellSize * 0.6), glyph: UInt8(ascii: "o"), fg: pal.eye.alpha(gulp), z: z + 0.002) }
    }

    func drawFins(_ w: World, _ g: CellGrid, _ pal: Palette, _ z: Float, _ fade: Double) {
        let col = pal.submerged(pal.fin, fade)
        let L = length
        // pectoral fins: swept back, flapping
        for (s, len, sweep) in [(0.26, 0.1, 0.9), (0.56, 0.055, 1.0)] {
            let f = spine.forward(atS: s), base = spine.point(at: s)
            let flap = sin(finPhase) * 0.25
            for k in [-1.0, 1.0] {
                let root = base + f.perp * (k * width(s) * 0.9)
                let dir = f.perp * k * cos(sweep + flap) - f * sin(sweep + flap)
                g.line(root, root + dir * (L * len), fg: col, z: z)
            }
        }
        // tail fin: a fan behind the last node, waving with the stroke
        let tf = spine.forward(at: spine.nodes.count - 1), tail = spine.tail
        let wave = sin(phase - 1.2) * 0.35
        for spread in [-0.5, 0.0, 0.5] {
            let dir = (-tf).rotated(spread + wave)
            g.line(tail, tail + dir * (L * (spread == 0 ? 0.08 : 0.12)), fg: col, z: z)
        }
    }
}
