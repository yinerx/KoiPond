import Foundation

/// Is a screen completely hidden behind other windows? Samples a grid of points over the screen and asks
/// whether every one of them falls inside some window. Used by the wallpaper, whose desktop-level windows
/// do not get reliable occlusion reports from the system.
public enum Coverage {
    public struct Rect: Equatable, Sendable {
        public var x: Double, y: Double, w: Double, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
        @inlinable public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && py >= y && px < x + w && py < y + h }
    }

    /// True if `windows` hide all of `screen` (same coordinate space), checked on a `cols × rows` grid.
    public static func isCovered(_ screen: Rect, by windows: [Rect], cols: Int = 16, rows: Int = 10) -> Bool {
        guard screen.w > 0, screen.h > 0, !windows.isEmpty else { return false }
        let candidates = windows.filter { $0.w > 0 && $0.h > 0 &&
            $0.x < screen.x + screen.w && $0.x + $0.w > screen.x && $0.y < screen.y + screen.h && $0.y + $0.h > screen.y }
        guard !candidates.isEmpty else { return false }
        for r in 0..<rows {
            for c in 0..<cols {
                let px = screen.x + (Double(c) + 0.5) / Double(cols) * screen.w
                let py = screen.y + (Double(r) + 0.5) / Double(rows) * screen.h
                if !candidates.contains(where: { $0.contains(px, py) }) { return false }
            }
        }
        return true
    }
}
