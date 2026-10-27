import XCTest
@testable import PondCore

/// Regression tests for v0.1.0's crash: drawing anything partly or wholly outside the grid trapped
/// on an inverted range (`100...99`) once a fish swam past the bottom or right edge.
final class RobustnessTests: XCTestCase {
    func testClipOutsideEveryEdge() {
        let g = CellGrid(width: 1200, height: 1200, cellSize: 12)   // 100 × 100 cells
        XCTAssertNil(g.clip(cols: 100, 120, rows: 10, 20), "right of the grid")
        XCTAssertNil(g.clip(cols: 10, 20, rows: 100, 120), "below the grid")
        XCTAssertNil(g.clip(cols: -30, -1, rows: 10, 20), "left of the grid")
        XCTAssertNil(g.clip(cols: 10, 20, rows: -30, -1), "above the grid")
        XCTAssertNil(g.clip(cols: 20, 10, rows: 10, 20), "inverted input")
        let s = g.clip(cols: -5, 105, rows: 95, 130)
        XCTAssertEqual(s?.cols, 0...99)
        XCTAssertEqual(s?.rows, 95...99)
    }

    func testCellOfNonFiniteDoesNotTrap() {
        let g = CellGrid(width: 600, height: 400, cellSize: 12)
        for p in [Vec2(.nan, 3), Vec2(.infinity, -.infinity), Vec2(1e300, -1e300)] {
            let (c, r) = g.cellOf(p)
            XCTAssertNil(g.index(c, r))
            g.put(p, glyph: 65, fg: RGBA(1, 2, 3), z: 1)
            g.line(Vec2(0, 0), p, fg: RGBA(1, 2, 3), z: 1)
        }
    }

    /// Every kind drawn into a grid much smaller than the world: most creatures sit beyond its edges.
    func testDrawingCreaturesBeyondTheGridEdges() {
        let groups = EntityKind.allCases.map { EntityGroup(kind: $0, count: min(4, $0.maxCount)) }
        let w = World(config: PondConfig(groups: groups), width: 2600, height: 1800, seed: 21)
        let small = CellGrid(width: 500, height: 360, cellSize: 12)
        for frame in 0..<(60 * 40) {
            w.tick(World.step)
            if frame % 6 == 0 { w.draw(into: small) }
            if frame % 300 == 0 { w.feed(at: Vec2(Double(frame % 2600), Double(frame % 1800))) }
        }
    }

    /// The window shrinking under the creatures (they are briefly off screen).
    func testShrinkingWindow() {
        let groups = EntityKind.allCases.map { EntityGroup(kind: $0, count: 2) }
        let w = World(config: PondConfig(groups: groups), width: 1800, height: 1200, seed: 4)
        let g = CellGrid()
        for (i, size) in [(1800.0, 1200.0), (300, 200), (90, 60), (2400, 1400), (40, 900), (1200, 30)].enumerated() {
            w.resize(width: size.0, height: size.1)
            g.resize(width: size.0, height: size.1, cellSize: 6 + Double(i) * 5)
            for f in 0..<240 { w.tick(World.step); if f % 10 == 0 { w.draw(into: g) } }
        }
    }

    /// Three simulated minutes of everything, fed repeatedly, at the default cell size.
    func testSoak() {
        let groups = EntityKind.allCases.map { EntityGroup(kind: $0, count: $0.defaultCount) }
        var gl = GlobalSettings(); gl.showFPS = true
        let w = World(config: PondConfig(global: gl, groups: groups), width: 1440, height: 900, seed: 99)
        let g = CellGrid(width: 1440, height: 900, cellSize: 12)
        for frame in 0..<(60 * 180) {
            w.tick(World.step)
            if frame % 4 == 0 { w.draw(into: g) }
            if frame % 240 == 0 { w.feed(at: Vec2(Double((frame * 37) % 1440), Double((frame * 53) % 900))) }
        }
        for c in w.creatures { XCTAssertTrue(c.position.x.isFinite && c.position.y.isFinite, "\(c.kind)") }
        XCTAssertGreaterThan(w.eaten, 0)
    }
}
