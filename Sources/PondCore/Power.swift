import Foundation

/// How hard the pond works. The character grid only changes a few times per second, so most of the
/// time a low frame rate looks the same; while something is happening (food, ripples, a fleeing fish)
/// the pond speeds up for a moment.
public enum PowerProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case saver, balanced, smooth
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .saver: return "省电"
        case .balanced: return "均衡"
        case .smooth: return "流畅"
        }
    }
    public var summary: String {
        switch self {
        case .saver: return "平时 \(Int(calmFPS)) 帧，互动时 \(Int(activeFPS)) 帧，低分辨率"
        case .balanced: return "平时 \(Int(calmFPS)) 帧，互动时 \(Int(activeFPS)) 帧，低分辨率"
        case .smooth: return "始终 \(Int(activeFPS)) 帧，原生分辨率"
        }
    }

    /// Frames per second while the pond is calm.
    public var calmFPS: Double {
        switch self { case .saver: return 6; case .balanced: return 12; case .smooth: return 60 }
    }
    /// Frames per second while something is going on.
    public var activeFPS: Double {
        switch self { case .saver: return 15; case .balanced: return 30; case .smooth: return 60 }
    }
    /// Render resolution relative to the screen's native pixels (0.5 = one pixel per point on Retina).
    public var resolutionScale: Double {
        switch self { case .saver: return 0.5; case .balanced: return 0.5; case .smooth: return 1.0 }
    }
    /// How long the fast rate lasts after the last activity, in seconds.
    public var activeHold: Double { 2.5 }

    public func fps(busy: Bool) -> Double { busy ? activeFPS : calmFPS }

    /// Low Power Mode and a hot machine both drop to the saver profile.
    public func effective(lowPowerMode: Bool, thermalSerious: Bool) -> PowerProfile {
        (lowPowerMode || thermalSerious) ? .saver : self
    }
}
