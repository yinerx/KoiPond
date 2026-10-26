import Foundation

/// A school of shrimp moving as a flock (cohesion, alignment, separation). Startled, they flick backwards and scatter.
public final class ShrimpSchool: Creature, Relocatable {
    struct Shrimp { var pos: Vec2; var vel: Vec2; var flick: Double = 0 }
    public let kind = EntityKind.shrimp
    public let groupID: UUID
    let size: Double
    var members: [Shrimp] = []
    var goal: Vec2
    var nextGoal: Double
    public var depth: Double
    public var position: Vec2 {
        guard !members.isEmpty else { return goal }
        return members.reduce(Vec2.zero) { $0 + $1.pos } / Double(members.count)
    }
    var bodyLen: Double { EntityKind.shrimp.baseLength * size }

    init(group g: EntityGroup, size: Double, at p: Vec2, world w: World) {
        groupID = g.id
        self.size = size
        goal = p
        nextGoal = w.time
        depth = w.rng.range(g.depthMin, g.depthMax)
        for _ in 0..<max(1, g.params.perSchool) {
            members.append(Shrimp(pos: p + Vec2(w.rng.range(-30, 30), w.rng.range(-30, 30)), vel: Vec2.polar(w.rng.angle(), 20)))
        }
    }

    func relocate(scaleX: Double, scaleY: Double) {
        goal = Vec2(goal.x * scaleX, goal.y * scaleY)
        for i in members.indices { members[i].pos = Vec2(members[i].pos.x * scaleX, members[i].pos.y * scaleY) }
    }

    public func startle(_ w: World, at p: Vec2, amount: Double) {
        for i in members.indices where members[i].pos.distance(to: p) < 120 {
            let away = (members[i].pos - p).normalized
            members[i].vel += away * (160 * (0.5 + amount))
            members[i].flick = 1
        }
    }
    public func feelRipple(_ w: World, from p: Vec2, strength: Double) {
        if strength > 0.2 { startle(w, at: p, amount: strength * 0.6) }
    }

    public func step(_ w: World, _ dt: Double) {
        guard let g = w.group(groupID) else { return }
        if w.time > nextGoal || goal.distance(to: position) < 30 {
            goal = Vec2(w.rng.range(0.1, 0.9) * w.width, w.rng.range(0.1, 0.9) * w.height)
            nextGoal = w.time + w.rng.range(6, 14)
        }
        let center = position
        var avgVel = Vec2.zero
        for m in members { avgVel += m.vel }
        avgVel = avgVel / Double(max(1, members.count))
        let cruise = 30 * g.speed * size.squareRoot()
        let personal = bodyLen * 0.95
        for i in members.indices {
            var m = members[i]
            var acc = (goal - m.pos).normalized * 14            // the school's errand
            acc += (center - m.pos) * 1.1                        // stay together
            acc += (avgVel - m.vel) * 0.8                        // swim the same way
            for j in members.indices where j != i {              // don't bump
                let d = m.pos - members[j].pos, l = d.length
                if l < personal && l > 0 { acc += d.normalized * (personal - l) * 6 }
            }
            acc += Vec2(w.rng.range(-1, 1), w.rng.range(-1, 1)) * 20
            m.vel += acc * dt
            let sp = m.vel.length
            if sp > cruise * (1 + 3 * m.flick) { m.vel = m.vel * (cruise * (1 + 3 * m.flick) / sp) }
            m.pos += m.vel * dt
            m.flick = max(0, m.flick - dt * 1.5)
            members[i] = m
        }
        depth += (clamp(depth, g.depthMin, g.depthMax) - depth) * dt
    }

    public func draw(_ w: World, _ g: CellGrid) {
        let pal = w.palette, z = Float(1 - depth)
        let col = pal.submerged(pal.shrimp, depth)
        for m in members {
            let dir = m.vel.normalized
            // head, a curved body behind it, feelers in front
            let head = m.pos
            g.put(head, glyph: UInt8(ascii: "e"), fg: col, bg: col.alpha(0.35), z: z)
            let tail = head - dir * bodyLen
            g.put(head - dir * (bodyLen * 0.5), glyph: Glyph.line(angle: dir.angle), fg: col.alpha(0.9), z: z - 0.001)
            g.put(tail, glyph: m.flick > 0.2 ? UInt8(ascii: "<") : UInt8(ascii: ","), fg: col.alpha(0.8), z: z - 0.001)
            g.put(head + dir * (bodyLen * 0.7), glyph: UInt8(ascii: "`"), fg: col.alpha(0.5), z: z - 0.002)
        }
    }
}
