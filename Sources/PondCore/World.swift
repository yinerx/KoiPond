import Foundation

// MARK: - Things in the water

public struct Pellet: Identifiable, Sendable {
    public let id: Int
    public var pos: Vec2
    public var vel: Vec2
    public let born: Double
    public let landAt: Double      // seconds after `born` it hits the water
    public var landed = false
}

public struct Ripple: Sendable {
    public var pos: Vec2
    public var born: Double
    public var strength: Double    // 0…1+
    public var speed: Double       // points per second
    public var life: Double
}

public struct Particle: Sendable {
    public enum Kind: Sendable { case ink, spray, bubble }
    public var kind: Kind
    public var pos: Vec2
    public var vel: Vec2
    public var born: Double
    public var life: Double
    public var glyph: UInt8
}

// MARK: - Creature protocol

public protocol Creature: AnyObject {
    var kind: EntityKind { get }
    var groupID: UUID { get }
    /// Head (swimmers) or centre (plants, jellyfish).
    var position: Vec2 { get }
    /// 0 = at the surface, 1 = deep.
    var depth: Double { get }
    func step(_ w: World, _ dt: Double)
    func draw(_ w: World, _ g: CellGrid)
    /// A ripple front passing at distance `d` from its centre.
    func feelRipple(_ w: World, from p: Vec2, strength: Double)
    /// Something scary (fast pointer, splash) happened at `p`.
    func startle(_ w: World, at p: Vec2, amount: Double)
}

public extension Creature {
    func feelRipple(_ w: World, from p: Vec2, strength: Double) {}
    func startle(_ w: World, at p: Vec2, amount: Double) {}
}

// MARK: - World

/// The whole pond: creatures, food, ripples, particles. Pure simulation; the renderer only reads the grid.
public final class World {
    public private(set) var config: PondConfig
    public private(set) var palette: Palette
    public private(set) var width: Double
    public private(set) var height: Double
    public private(set) var time: Double = 0
    public var rng: PondRandom

    public private(set) var creatures: [Creature] = []
    public private(set) var pellets: [Pellet] = []
    public private(set) var ripples: [Ripple] = []
    public private(set) var particles: [Particle] = []
    public private(set) var eaten = 0
    public var fps: Double = 0
    /// Performance lines drawn bottom-left when "show performance" is on (filled in by the renderer).
    public var hudLines: [String] = []
    /// Last moment something visibly happened: food, ripples, particles, a fast pointer, a fleeing animal.
    public private(set) var lastBusy: Double = -100

    // pointer
    public private(set) var pointer = Vec2(-1e9, -1e9)
    public private(set) var pointerSpeed: Double = 0
    public private(set) var pointerActive = false
    public private(set) var lastFeed: Double = -100

    private var nextPelletID = 0
    private var groupsByID: [UUID: EntityGroup] = [:]
    private var accumulator: Double = 0
    public static let step: Double = 1.0 / 60.0

    public init(config: PondConfig, width: Double, height: Double, seed: UInt64? = nil) {
        let cfg = config.sanitized()
        self.config = cfg
        self.palette = Palette.make(cfg.global)
        self.width = max(1, width)
        self.height = max(1, height)
        let s = seed ?? (cfg.global.seed != 0 ? cfg.global.seed : UInt64.random(in: 1...UInt64.max))
        self.rng = PondRandom(seed: s)
        apply(config: cfg)
    }

    // MARK: configuration

    public func group(_ id: UUID) -> EntityGroup? { groupsByID[id] }

    /// Applies a new configuration live. Groups whose look did not change keep their creatures;
    /// changed groups are respawned; count changes add or remove individuals.
    public func apply(config new: PondConfig) {
        let cfg = new.sanitized()
        let old = groupsByID
        config = cfg
        palette = Palette.make(cfg.global)
        groupsByID = Dictionary(cfg.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var kept: [Creature] = []
        for c in creatures {
            guard let g = groupsByID[c.groupID], g.enabled, let o = old[c.groupID], o.sameLook(as: g) else { continue }
            kept.append(c)
        }
        creatures = kept
        for g in cfg.groups where g.enabled {
            let have = creatures.filter { $0.groupID == g.id }
            if have.count > g.count {
                let drop = Set(have.suffix(have.count - g.count).map { ObjectIdentifier($0) })
                creatures.removeAll { drop.contains(ObjectIdentifier($0)) }
            } else if have.count < g.count {
                for _ in have.count..<g.count { creatures.append(spawn(g)) }
            }
        }
    }

    public func resize(width w: Double, height h: Double) {
        let sx = max(1, w) / width, sy = max(1, h) / height
        width = max(1, w); height = max(1, h)
        guard abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 else { return }
        for c in creatures { (c as? Relocatable)?.relocate(scaleX: sx, scaleY: sy) }
    }

    func spawn(_ g: EntityGroup) -> Creature {
        let size = rng.range(g.sizeMin, g.sizeMax)
        let p = Vec2(rng.range(0.08, 0.92) * width, rng.range(0.08, 0.92) * height)
        switch g.kind {
        case .koi: return Koi(group: g, size: size, at: p, world: self)
        case .whale: return Whale(group: g, size: size, at: p, world: self)
        case .jellyfish: return Jellyfish(group: g, size: size, at: p, world: self)
        case .squid: return Squid(group: g, size: size, at: p, world: self)
        case .turtle: return Turtle(group: g, size: size, at: p, world: self)
        case .shrimp: return ShrimpSchool(group: g, size: size, at: p, world: self)
        case .duckweed: return Duckweed(group: g, size: size, at: p, world: self)
        case .waterLily: return WaterLily(group: g, size: size, at: p, world: self)
        }
    }

    public var koiCount: Int { creatures.reduce(0) { $0 + ($1.kind == .koi ? 1 : 0) } }
    public var pelletCount: Int { pellets.count }
    public var anyoneFeeds: Bool { config.groups.contains { $0.enabled && $0.kind.canBeFed && $0.feedable && $0.count > 0 } }

    // MARK: input

    /// A click: one ripple, and a handful of food pellets scattered around it.
    public func feed(at p: Vec2) {
        lastFeed = time
        addRipple(at: p, strength: 0.6)
        let g = config.global
        let n = min(g.pelletsPerClick, max(0, g.maxPellets - pellets.count))
        for _ in 0..<n {
            let a = rng.angle(), r = 30 * rng.unit().squareRoot(), s = rng.range(2, 8)
            pellets.append(Pellet(id: nextPelletID, pos: p + Vec2(cos(a) * r * 1.3, sin(a) * r),
                                  vel: Vec2.polar(a, s), born: time, landAt: rng.range(0.15, 0.45)))
            nextPelletID += 1
        }
        for c in creatures { c.startle(self, at: p, amount: 0.35) }
    }

    /// A ripple without food (wallpaper clicks on icons, tests, splashes).
    public func addRipple(at p: Vec2, strength: Double, speed: Double = 70) {
        let g = config.global
        guard g.rippleStrength > 0 else { return }
        ripples.append(Ripple(pos: p, born: time, strength: strength * g.rippleStrength,
                              speed: speed, life: g.rippleLifetime * (0.6 + 0.5 * strength)))
    }

    public func pointerMoved(to p: Vec2, dt: Double) {
        if pointerActive, dt > 0 {
            let v = p.distance(to: pointer) / dt
            pointerSpeed = max(pointerSpeed * 0.5, v)
        }
        pointer = p; pointerActive = true
    }
    public func pointerExited() { pointerActive = false; pointerSpeed = 0 }

    public func emit(_ kind: Particle.Kind, at p: Vec2, vel: Vec2, life: Double, glyph: UInt8) {
        guard particles.count < 1500 else { return }
        particles.append(Particle(kind: kind, pos: p, vel: vel, born: time, life: life, glyph: glyph))
    }

    // MARK: food

    public func nearestPellet(to p: Vec2, within r: Double) -> Pellet? {
        var best: Pellet?, bd = r * r
        for q in pellets where q.landed {
            let d = (q.pos - p).lengthSquared
            if d < bd { bd = d; best = q }
        }
        return best
    }
    public func pellet(_ id: Int) -> Pellet? { pellets.first { $0.id == id } }
    @discardableResult
    public func eat(_ id: Int) -> Bool {
        guard let i = pellets.firstIndex(where: { $0.id == id }) else { return false }
        let p = pellets.remove(at: i)
        eaten += 1
        addRipple(at: p.pos, strength: 0.25, speed: 55)
        return true
    }

    // MARK: simulation

    /// Advances by real time `dt`, in fixed steps.
    public func advance(_ dt: Double) {
        accumulator += min(0.25, max(0, dt)) * config.global.simulationSpeed
        var n = 0
        while accumulator >= World.step && n < 12 { tick(World.step); accumulator -= World.step; n += 1 }
        if n == 12 { accumulator = 0 }
        pointerSpeed *= exp(-8 * dt)
    }

    /// True while the pond should run at its fast frame rate (activity, plus `hold` seconds after it).
    public func wantsFastFrames(hold: Double) -> Bool { time - lastBusy < hold }

    /// Something visible is happening right now.
    public var isBusyNow: Bool {
        if !pellets.isEmpty || !ripples.isEmpty || !particles.isEmpty { return true }
        if pointerActive && pointerSpeed > 300 { return true }
        return creatures.contains { ($0 as? SpineSwimmer).map { $0.fear > 0.05 } ?? false }
    }

    func tick(_ dt: Double) {
        time += dt
        if isBusyNow { lastBusy = time }
        let g = config.global
        // pellets: fly, land (small ripple, koi notice), drift, dissolve
        var landedNow: [Vec2] = []
        for i in pellets.indices {
            if !pellets[i].landed {
                if time - pellets[i].born >= pellets[i].landAt { pellets[i].landed = true; landedNow.append(pellets[i].pos) }
                else { pellets[i].pos += pellets[i].vel * dt * 6 }
            } else {
                pellets[i].vel *= exp(-0.6 * dt)
                pellets[i].pos += pellets[i].vel * dt
            }
        }
        for p in landedNow { addRipple(at: p, strength: 0.12, speed: 45) }
        pellets.removeAll { time - $0.born > g.pelletLifetime }

        // ripples: the front pushes whatever it passes
        ripples.removeAll { time - $0.born > $0.life }
        for r in ripples {
            let age = time - r.born, radius = age * r.speed, fade = 1 - age / r.life
            for c in creatures {
                let d = c.position.distance(to: r.pos)
                if abs(d - radius) < r.speed * dt * 1.5 + 2 { c.feelRipple(self, from: r.pos, strength: r.strength * fade) }
            }
        }

        // a fast pointer scares nearby swimmers
        if pointerActive && pointerSpeed > 900 && time - lastFeed > 1.5 {
            for c in creatures where c.position.distance(to: pointer) < 140 { c.startle(self, at: pointer, amount: min(1, pointerSpeed / 2400)) }
        }

        for c in creatures { c.step(self, dt) }

        // particles
        for i in particles.indices {
            let drag: Double = particles[i].kind == .ink ? 2.2 : 1.4
            particles[i].vel *= exp(-drag * dt)
            particles[i].pos += particles[i].vel * dt
        }
        particles.removeAll { time - $0.born > $0.life }
    }

    // MARK: drawing

    /// Rasterizes the whole pond into `grid` (sized to the world by the caller).
    public func draw(into grid: CellGrid) {
        grid.clear()
        // deep first, so nearer things cover them
        for c in creatures.sorted(by: { $0.depth > $1.depth }) { c.draw(self, grid) }

        let pal = palette
        for p in pellets {
            let age = time - p.born, life = config.global.pelletLifetime
            let fade = 1 - smoothstep(life - 2, life, age)
            if p.landed {
                grid.put(p.pos, glyph: UInt8(ascii: "o"), fg: pal.pellet.alpha(fade), z: 3)
            } else {
                grid.put(p.pos + Vec2(0, -6), glyph: Glyph.degree, fg: pal.pellet.alpha(0.8), z: 3)
            }
        }
        for r in ripples { drawRipple(r, grid) }
        for q in particles {
            let f = 1 - (time - q.born) / q.life
            let col: RGBA
            switch q.kind {
            case .ink: col = pal.ink.alpha(0.9 * f)
            case .spray: col = pal.eye.alpha(0.85 * f)
            case .bubble: col = pal.ripple.alpha(0.8 * f)
            }
            let (cx, cy) = grid.cellOf(q.pos)
            if q.kind == .ink { grid.put(cx, cy, glyph: q.glyph, fg: col, bg: pal.ink.alpha(0.55 * f), z: 2.5) }
            else { grid.overlay(cx, cy, glyph: q.glyph, fg: col, onlyEmpty: false) }
        }
        if config.global.showCounter { drawCounter(grid) }
        if config.global.showFPS {
            let lines = hudLines.isEmpty ? [String(format: "%.0f fps", fps)] : hudLines
            for (i, l) in lines.enumerated() { drawText(l, col: 1, row: grid.rows - 1 - lines.count + i, grid) }
        }
    }

    func drawRipple(_ r: Ripple, _ g: CellGrid) {
        let age = time - r.born, radius = age * r.speed
        let fade = (1 - age / r.life) * min(1, r.strength * 1.6)
        guard fade > 0.02, radius > 2 else { return }
        let col = palette.ripple.alpha(fade)
        for (k, rad) in [radius, radius * 0.62].enumerated() where k == 0 || r.strength > 0.3 {
            let n = max(8, Int(2 * .pi * rad / (g.cellSize * 0.8)))
            let c2 = k == 0 ? col : col.alpha(0.6)
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                // slightly flattened: the pond is seen at a shallow angle
                let q = Vec2(r.pos.x + cos(a) * rad, r.pos.y + sin(a) * rad * 0.8)
                let (cx, cy) = g.cellOf(q)
                let glyph = fade < 0.25 ? UInt8(ascii: ".") : Glyph.line(angle: atan2(cos(a) * 0.8, -sin(a)))
                g.overlay(cx, cy, glyph: glyph, fg: c2)
            }
        }
    }

    func drawCounter(_ g: CellGrid) {
        let col = g.cols - 6
        drawText("\(koiCount)", col: col, row: 2, g)
        drawText("\(pelletCount)", col: col, row: 3, g)
    }
    func drawText(_ s: String, col: Int, row: Int, _ g: CellGrid) {
        for (i, ch) in s.enumerated() { g.put(col + i, row, glyph: Glyph.ascii(ch), fg: palette.text.alpha(0.6), z: 10) }
    }
}

/// Creatures that keep their place when the window is resized.
protocol Relocatable { func relocate(scaleX: Double, scaleY: Double) }

extension EntityGroup {
    /// Changes that need fresh individuals (size, kind, look); speed/depth/behaviour apply live.
    func sameLook(as o: EntityGroup) -> Bool {
        kind == o.kind && sizeMin == o.sizeMin && sizeMax == o.sizeMax &&
            params.varieties == o.params.varieties && params.hue == o.params.hue &&
            params.perSchool == o.params.perSchool && params.clusterSize == o.params.clusterSize &&
            params.flowerChance == o.params.flowerChance && params.tentacleLength == o.params.tentacleLength
    }
}
