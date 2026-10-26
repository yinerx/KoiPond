import Foundation

/// Glyph codes. 32…126 are ASCII; a few extra shapes live above 127. The renderer's atlas follows this table.
public enum Glyph {
    public static let space: UInt8 = 32
    public static let middleDot: UInt8 = 128   // ·
    public static let degree: UInt8 = 129      // °
    public static let bullet: UInt8 = 130      // •
    public static let ring: UInt8 = 131        // ○
    public static let wave: UInt8 = 132        // ≈
    public static let tilde: UInt8 = 126       // ~

    /// Every code the renderer must be able to draw, with the character it stands for.
    public static let table: [(UInt8, Character)] = {
        var t: [(UInt8, Character)] = (32...126).map { (UInt8($0), Character(UnicodeScalar(UInt8($0)))) }
        t += [(middleDot, "·"), (degree, "°"), (bullet, "•"), (ring, "○"), (wave, "≈")]
        return t
    }()

    @inlinable public static func ascii(_ c: Character) -> UInt8 { c.asciiValue ?? space }

    /// A line glyph that follows a direction: '-', '\', '|', '/' (screen y grows downward).
    @inlinable public static func line(angle: Double) -> UInt8 {
        var a = angle.truncatingRemainder(dividingBy: .pi)
        if a < 0 { a += .pi }
        let k = Int((a / (.pi / 4)).rounded()) % 4
        return [UInt8(ascii: "-"), UInt8(ascii: "\\"), UInt8(ascii: "|"), UInt8(ascii: "/")][k]
    }
}

public struct Cell: Equatable, Sendable {
    public var glyph: UInt8
    public var fg: RGBA
    public var bg: RGBA
    /// Depth of whatever was stamped last: larger = nearer the surface. Stamps never cover nearer ones.
    public var z: Float
    public static let empty = Cell(glyph: Glyph.space, fg: .clear, bg: .clear, z: -.greatestFiniteMagnitude)
}

/// The screen as a grid of character cells. Creatures rasterize themselves into it every frame.
public final class CellGrid {
    public private(set) var cols: Int = 0
    public private(set) var rows: Int = 0
    public private(set) var cellSize: Double = 12
    public var cells: [Cell] = []

    public init(width: Double = 0, height: Double = 0, cellSize: Double = 12) {
        resize(width: width, height: height, cellSize: cellSize)
    }

    /// Size in points; returns true if the grid changed.
    @discardableResult
    public func resize(width: Double, height: Double, cellSize: Double) -> Bool {
        let cs = max(4, cellSize)
        let c = max(1, Int((width / cs).rounded(.up))), r = max(1, Int((height / cs).rounded(.up)))
        guard c != cols || r != rows || cs != self.cellSize else { return false }
        cols = c; rows = r; self.cellSize = cs
        cells = Array(repeating: .empty, count: c * r)
        return true
    }

    public func clear() {
        cells.withUnsafeMutableBufferPointer { p in for i in p.indices { p[i] = .empty } }
    }

    @inlinable public func index(_ col: Int, _ row: Int) -> Int? {
        (col >= 0 && row >= 0 && col < cols && row < rows) ? row * cols + col : nil
    }
    @inlinable public func cellOf(_ p: Vec2) -> (Int, Int) { (Int(floor(p.x / cellSize)), Int(floor(p.y / cellSize))) }
    @inlinable public func center(_ col: Int, _ row: Int) -> Vec2 { Vec2((Double(col) + 0.5) * cellSize, (Double(row) + 0.5) * cellSize) }

    /// Writes a cell if `z` is at least as near as what is there. A clear bg keeps the old bg.
    @inlinable public func put(_ col: Int, _ row: Int, glyph: UInt8, fg: RGBA, bg: RGBA = .clear, z: Float) {
        guard let i = index(col, row), z >= cells[i].z else { return }
        var c = cells[i]
        c.glyph = glyph; c.fg = fg; c.z = z
        if bg.a > 0 { c.bg = bg }
        cells[i] = c
    }
    /// Background only (shadows, tiles); keeps glyphs of nearer stamps.
    @inlinable public func tint(_ col: Int, _ row: Int, bg: RGBA, z: Float) {
        guard let i = index(col, row) else { return }
        if z >= cells[i].z { cells[i].bg = bg; cells[i].z = z; cells[i].glyph = Glyph.space }
    }
    /// Glyph overlay that ignores depth but only where nothing visible sits (ripples, ink, spray).
    @inlinable public func overlay(_ col: Int, _ row: Int, glyph: UInt8, fg: RGBA, onlyEmpty: Bool = true) {
        guard let i = index(col, row) else { return }
        if onlyEmpty && (cells[i].glyph != Glyph.space || cells[i].bg.a > 0) { return }
        cells[i].glyph = glyph; cells[i].fg = fg
    }
    public func put(_ p: Vec2, glyph: UInt8, fg: RGBA, bg: RGBA = .clear, z: Float) {
        let (c, r) = cellOf(p); put(c, r, glyph: glyph, fg: fg, bg: bg, z: z)
    }

    /// A line of direction-following glyphs from a to b.
    public func line(_ a: Vec2, _ b: Vec2, fg: RGBA, z: Float, glyph: UInt8? = nil) {
        let d = b - a, len = d.length
        let steps = max(1, Int(len / (cellSize * 0.6)))
        let g = glyph ?? Glyph.line(angle: d.angle)
        var last = (Int.min, Int.min)
        for s in 0...steps {
            let p = a + d * (Double(s) / Double(steps))
            let cr = cellOf(p)
            if cr == last { continue }
            last = cr
            put(cr.0, cr.1, glyph: g, fg: fg, z: z)
        }
    }

    /// Text for debugging / tests: one string per row.
    public func dump() -> [String] {
        (0..<rows).map { r in
            String((0..<cols).map { c -> Character in
                let g = cells[r * cols + c].glyph
                return g < 127 ? Character(UnicodeScalar(g)) : "*"
            })
        }
    }
}
