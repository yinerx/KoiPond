import Foundation

// MARK: - Vector

public struct Vec2: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }
    public static func *= (a: inout Vec2, s: Double) { a = a * s }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }
    public var normalized: Vec2 { let l = length; return l > 1e-9 ? self / l : Vec2(1, 0) }
    public var angle: Double { atan2(y, x) }
    /// Perpendicular, rotated +90°.
    public var perp: Vec2 { Vec2(-y, x) }
    public func dot(_ b: Vec2) -> Double { x * b.x + y * b.y }
    public func cross(_ b: Vec2) -> Double { x * b.y - y * b.x }
    public func distance(to b: Vec2) -> Double { (self - b).length }
    public func rotated(_ a: Double) -> Vec2 { let c = cos(a), s = sin(a); return Vec2(x * c - y * s, x * s + y * c) }
    public static func polar(_ angle: Double, _ r: Double = 1) -> Vec2 { Vec2(cos(angle) * r, sin(angle) * r) }
    public func limited(_ maxLen: Double) -> Vec2 { let l = length; return l > maxLen ? self * (maxLen / l) : self }
}

// MARK: - Scalars

@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
@inlinable public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inlinable public func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t)
}
/// Wraps an angle to (-π, π].
@inlinable public func wrapAngle(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r > .pi { r -= 2 * .pi } else if r <= -.pi { r += 2 * .pi }
    return r
}
/// Turns `from` toward `to` by at most `maxStep` radians.
@inlinable public func turn(_ from: Double, toward to: Double, maxStep: Double) -> Double {
    let d = wrapAngle(to - from)
    return from + clamp(d, -maxStep, maxStep)
}

// MARK: - Random

/// Small, fast, seedable generator (SplitMix64) so a pond can be reproduced from a seed.
public struct PondRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    public mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(max(1, hi - lo + 1))) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
    public mutating func angle() -> Double { range(-.pi, .pi) }
}

/// Stateless hash in [0, 1) — for per-cell texture that must not flicker between frames.
@inlinable public func hash01(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
    var h = UInt32(truncatingIfNeeded: a &* 374_761_393 &+ b &* 668_265_263 &+ c &* 1_274_126_177)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h) / 4_294_967_296.0
}

// MARK: - Colour

public struct RGBA: Equatable, Codable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }
    public static let clear = RGBA(0, 0, 0, 0)

    /// "#rrggbb" or "#rrggbbaa"; returns nil for anything else.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
        } else {
            self.init(UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
        }
    }
    public var hex: String { String(format: "#%02x%02x%02x", r, g, b) }

    public func alpha(_ f: Double) -> RGBA { RGBA(r, g, b, UInt8(clamp(Double(a) * f, 0, 255))) }
    public func mixed(with o: RGBA, _ t: Double) -> RGBA {
        let t = clamp(t, 0, 1)
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8(clamp(lerp(Double(x), Double(y), t), 0, 255)) }
        return RGBA(m(r, o.r), m(g, o.g), m(b, o.b), m(a, o.a))
    }
    /// Packed as 0xAABBGGRR (little-endian RGBA bytes), the layout the GPU reads.
    public var packed: UInt32 { UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24 }
}
