import XCTest
import Foundation
@testable import PondCore

/// Dev aid: with POND_PREVIEW=<dir>, writes grid snapshots as JSON for an offline PNG preview. Skipped otherwise.
final class PreviewDump: XCTestCase {
    func testDump() throws {
        guard let dir = ProcessInfo.processInfo.environment["POND_PREVIEW"] else { throw XCTSkip("POND_PREVIEW not set") }
        let scenes: [(String, PondConfig)] = Preset.allCases.map { ($0.rawValue, $0.config) } + [
            ("all", PondConfig(groups: EntityKind.allCases.map { EntityGroup(kind: $0, count: $0 == .whale ? 1 : 2) })),
        ]
        for (name, cfg) in scenes {
            let w = World(config: cfg, width: 1440, height: 900, seed: 11)
            for _ in 0..<(60 * 4) { w.tick(World.step) }
            w.feed(at: Vec2(900, 450))
            for _ in 0..<(60 * 1) { w.tick(World.step) }
            let g = CellGrid(width: 1440, height: 900, cellSize: w.config.global.cellSize)
            w.draw(into: g)
            var cells: [[Any]] = []
            for (i, c) in g.cells.enumerated() where c.glyph != Glyph.space || c.bg.a > 0 {
                cells.append([i % g.cols, i / g.cols, Int(c.glyph), c.fg.hex, Int(c.fg.a), c.bg.hex, Int(c.bg.a)])
            }
            let obj: [String: Any] = ["cols": g.cols, "rows": g.rows, "cell": g.cellSize, "gap": w.config.global.tileGap,
                                      "bg": w.palette.background.hex, "cells": cells]
            let data = try JSONSerialization.data(withJSONObject: obj)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).json"))
        }
    }
}
