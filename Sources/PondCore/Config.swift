import Foundation

// MARK: - Kinds

public enum EntityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case koi, jellyfish, whale, squid, turtle, shrimp, duckweed, waterLily
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .koi: return "锦鲤"
        case .jellyfish: return "水母"
        case .whale: return "鲸鱼"
        case .squid: return "乌贼"
        case .turtle: return "乌龟"
        case .shrimp: return "虾群"
        case .duckweed: return "浮萍"
        case .waterLily: return "睡莲"
        }
    }
    /// Only koi come for food.
    public var canBeFed: Bool { self == .koi }
    /// Plants float at the surface and do not swim.
    public var isPlant: Bool { self == .duckweed || self == .waterLily }
    /// Base body length in points at scale 1.
    public var baseLength: Double {
        switch self {
        case .koi: return 330
        case .jellyfish: return 120
        case .whale: return 880
        case .squid: return 200
        case .turtle: return 190
        case .shrimp: return 30
        case .duckweed: return 80
        case .waterLily: return 150
        }
    }
    public var defaultCount: Int {
        switch self {
        case .koi: return 6
        case .jellyfish: return 4
        case .whale: return 1
        case .squid: return 2
        case .turtle: return 2
        case .shrimp: return 1
        case .duckweed: return 6
        case .waterLily: return 3
        }
    }
    /// Upper bound offered in the panel (keeps the frame rate sane).
    public var maxCount: Int {
        switch self {
        case .whale: return 3
        case .shrimp: return 6
        case .waterLily: return 12
        default: return 40
        }
    }
}

public enum KoiVariety: String, Codable, CaseIterable, Identifiable, Sendable {
    case kohaku, sanke, showa, ogon, asagi, tancho
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .kohaku: return "红白"
        case .sanke: return "大正三色"
        case .showa: return "昭和三色"
        case .ogon: return "黄金"
        case .asagi: return "浅黄"
        case .tancho: return "丹顶"
        }
    }
}

// MARK: - Per-kind parameters

/// Parameters for one kind. Every field has a default, so old or partial JSON still decodes.
public struct KindParams: Codable, Equatable, Sendable {
    // koi
    public var varieties: [String: Double] = ["kohaku": 4, "sanke": 2, "showa": 1, "ogon": 1, "asagi": 1, "tancho": 1]
    public var curiosity: Double = 0.7          // 0…1, how readily a koi goes for food
    public var foodRange: Double = 420          // points
    public var startleSensitivity: Double = 0.6 // 0…1
    // jellyfish
    public var pulseRate: Double = 0.5          // pulses per second
    public var tentacleLength: Double = 1.0     // × body size
    public var opacity: Double = 0.85
    public var hue: String = "#e6b3f0"
    // whale
    public var spoutInterval: Double = 18       // seconds
    // squid
    public var jetRate: Double = 0.35           // jets per second
    public var inkEnabled: Bool = true
    // turtle
    public var surfaceInterval: Double = 14
    // shrimp
    public var perSchool: Int = 24
    // duckweed
    public var clusterSize: Int = 14
    // water lily
    public var flowerChance: Double = 0.6

    public init() {}

    private enum K: String, CodingKey {
        case varieties, curiosity, foodRange, startleSensitivity, pulseRate, tentacleLength, opacity, hue,
             spoutInterval, jetRate, inkEnabled, surfaceInterval, perSchool, clusterSize, flowerChance
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = KindParams.make()
        varieties = try c.decodeIfPresent([String: Double].self, forKey: .varieties) ?? d.varieties
        curiosity = try c.decodeIfPresent(Double.self, forKey: .curiosity) ?? d.curiosity
        foodRange = try c.decodeIfPresent(Double.self, forKey: .foodRange) ?? d.foodRange
        startleSensitivity = try c.decodeIfPresent(Double.self, forKey: .startleSensitivity) ?? d.startleSensitivity
        pulseRate = try c.decodeIfPresent(Double.self, forKey: .pulseRate) ?? d.pulseRate
        tentacleLength = try c.decodeIfPresent(Double.self, forKey: .tentacleLength) ?? d.tentacleLength
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        hue = try c.decodeIfPresent(String.self, forKey: .hue) ?? d.hue
        spoutInterval = try c.decodeIfPresent(Double.self, forKey: .spoutInterval) ?? d.spoutInterval
        jetRate = try c.decodeIfPresent(Double.self, forKey: .jetRate) ?? d.jetRate
        inkEnabled = try c.decodeIfPresent(Bool.self, forKey: .inkEnabled) ?? d.inkEnabled
        surfaceInterval = try c.decodeIfPresent(Double.self, forKey: .surfaceInterval) ?? d.surfaceInterval
        perSchool = try c.decodeIfPresent(Int.self, forKey: .perSchool) ?? d.perSchool
        clusterSize = try c.decodeIfPresent(Int.self, forKey: .clusterSize) ?? d.clusterSize
        flowerChance = try c.decodeIfPresent(Double.self, forKey: .flowerChance) ?? d.flowerChance
    }
    private static func make() -> KindParams { KindParams() }
}

// MARK: - Groups

/// A group of identical-kind entities. Each individual gets a random size between `sizeMin` and `sizeMax`.
public struct EntityGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var kind: EntityKind
    public var name: String
    public var enabled: Bool = true
    public var count: Int
    /// Body size as a multiple of the kind's base length (1 = normal).
    public var sizeMin: Double = 0.85
    public var sizeMax: Double = 1.15
    /// Speed multiplier.
    public var speed: Double = 1.0
    /// 0 = at the surface, 1 = deepest visible. Deeper creatures fade into the water.
    public var depthMin: Double = 0.0
    public var depthMax: Double = 0.6
    /// Ignored for anything but koi.
    public var feedable: Bool = true
    public var params: KindParams = KindParams()

    public init(kind: EntityKind, count: Int? = nil, sizeMin: Double = 0.85, sizeMax: Double = 1.15, name: String? = nil) {
        self.kind = kind
        self.name = name ?? kind.displayName
        self.count = count ?? kind.defaultCount
        self.sizeMin = sizeMin
        self.sizeMax = sizeMax
        if kind.isPlant { depthMin = 0; depthMax = 0 }
        if kind == .whale { depthMin = 0.2; depthMax = 0.9; speed = 0.8; self.sizeMin = min(sizeMin, 0.7); self.sizeMax = min(sizeMax, 0.85) }
        if kind == .jellyfish { depthMin = 0.1; depthMax = 0.7 }
    }

    /// Clamps values a hand-edited file might get wrong.
    public func sanitized() -> EntityGroup {
        var g = self
        g.count = clamp(g.count, 0, kind.maxCount)
        g.sizeMin = clamp(g.sizeMin, 0.2, 4)
        g.sizeMax = clamp(max(g.sizeMax, g.sizeMin), 0.2, 4)
        g.speed = clamp(g.speed, 0, 4)
        g.depthMin = clamp(g.depthMin, 0, 1)
        g.depthMax = clamp(max(g.depthMax, g.depthMin), 0, 1)
        if !kind.canBeFed { g.feedable = false }
        return g
    }

    private enum K: String, CodingKey { case id, kind, name, enabled, count, sizeMin, sizeMax, speed, depthMin, depthMax, feedable, params }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kind = try c.decode(EntityKind.self, forKey: .kind)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? kind.displayName
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? kind.defaultCount
        sizeMin = try c.decodeIfPresent(Double.self, forKey: .sizeMin) ?? 0.85
        sizeMax = try c.decodeIfPresent(Double.self, forKey: .sizeMax) ?? 1.15
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        depthMin = try c.decodeIfPresent(Double.self, forKey: .depthMin) ?? 0
        depthMax = try c.decodeIfPresent(Double.self, forKey: .depthMax) ?? 0.6
        feedable = try c.decodeIfPresent(Bool.self, forKey: .feedable) ?? kind.canBeFed
        params = try c.decodeIfPresent(KindParams.self, forKey: .params) ?? KindParams()
    }
}

// MARK: - Global settings

public enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark, light
    public var id: String { rawValue }
    public var displayName: String { self == .dark ? "深色" : "浅色" }
}

public struct GlobalSettings: Codable, Equatable, Sendable {
    public var theme: Theme = .dark
    /// Empty = the theme's own colour.
    public var backgroundHex: String = ""
    public var cellSize: Double = 12          // points per character cell
    public var tileGap: Double = 1.5          // gap around body tiles, points
    public var simulationSpeed: Double = 1.0
    public var rippleStrength: Double = 1.0
    public var rippleLifetime: Double = 2.4   // seconds
    public var pelletsPerClick: Int = 6
    public var maxPellets: Int = 24
    public var pelletLifetime: Double = 14
    public var showCounter: Bool = true
    public var showFPS: Bool = false
    public var shadows: Bool = true
    public var seed: UInt64 = 0               // 0 = random each launch
    public init() {}

    private enum K: String, CodingKey {
        case theme, backgroundHex, cellSize, tileGap, simulationSpeed, rippleStrength, rippleLifetime,
             pelletsPerClick, maxPellets, pelletLifetime, showCounter, showFPS, shadows, seed
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .dark
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? ""
        cellSize = try c.decodeIfPresent(Double.self, forKey: .cellSize) ?? 12
        tileGap = try c.decodeIfPresent(Double.self, forKey: .tileGap) ?? 1.5
        simulationSpeed = try c.decodeIfPresent(Double.self, forKey: .simulationSpeed) ?? 1
        rippleStrength = try c.decodeIfPresent(Double.self, forKey: .rippleStrength) ?? 1
        rippleLifetime = try c.decodeIfPresent(Double.self, forKey: .rippleLifetime) ?? 2.4
        pelletsPerClick = try c.decodeIfPresent(Int.self, forKey: .pelletsPerClick) ?? 6
        maxPellets = try c.decodeIfPresent(Int.self, forKey: .maxPellets) ?? 24
        pelletLifetime = try c.decodeIfPresent(Double.self, forKey: .pelletLifetime) ?? 14
        showCounter = try c.decodeIfPresent(Bool.self, forKey: .showCounter) ?? true
        showFPS = try c.decodeIfPresent(Bool.self, forKey: .showFPS) ?? false
        shadows = try c.decodeIfPresent(Bool.self, forKey: .shadows) ?? true
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
    }

    public func sanitized() -> GlobalSettings {
        var s = self
        s.cellSize = clamp(s.cellSize, 6, 32)
        s.tileGap = clamp(s.tileGap, 0, s.cellSize / 3)
        s.simulationSpeed = clamp(s.simulationSpeed, 0, 4)
        s.rippleStrength = clamp(s.rippleStrength, 0, 3)
        s.rippleLifetime = clamp(s.rippleLifetime, 0.3, 8)
        s.pelletsPerClick = clamp(s.pelletsPerClick, 0, 30)
        s.maxPellets = clamp(s.maxPellets, 0, 200)
        s.pelletLifetime = clamp(s.pelletLifetime, 1, 120)
        return s
    }
}

// MARK: - Whole configuration

public struct PondConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int = PondConfig.currentVersion
    public var global: GlobalSettings = GlobalSettings()
    public var groups: [EntityGroup] = []
    public init(global: GlobalSettings = GlobalSettings(), groups: [EntityGroup] = []) {
        self.global = global; self.groups = groups
    }

    public func sanitized() -> PondConfig {
        var c = self
        c.global = global.sanitized()
        c.groups = groups.map { $0.sanitized() }
        return c
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
    public static func decode(_ data: Data) throws -> PondConfig {
        try JSONDecoder().decode(PondConfig.self, from: data).sanitized()
    }

    private enum K: String, CodingKey { case version, global, groups }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        global = try c.decodeIfPresent(GlobalSettings.self, forKey: .global) ?? GlobalSettings()
        groups = try c.decodeIfPresent([EntityGroup].self, forKey: .groups) ?? []
    }
}

// MARK: - Presets

public enum Preset: String, CaseIterable, Identifiable, Sendable {
    case koiPond, deepSea, mixed, lilyPond
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .koiPond: return "锦鲤池"
        case .deepSea: return "深海"
        case .mixed: return "混养"
        case .lilyPond: return "睡莲池"
        }
    }
    public var config: PondConfig {
        switch self {
        case .koiPond:
            return PondConfig(groups: [EntityGroup(kind: .koi, count: 6)])
        case .deepSea:
            var g = GlobalSettings(); g.backgroundHex = "#0e1420"
            return PondConfig(global: g, groups: [
                EntityGroup(kind: .jellyfish, count: 6, sizeMin: 0.7, sizeMax: 1.4),
                EntityGroup(kind: .whale, count: 1),
                EntityGroup(kind: .squid, count: 3),
                EntityGroup(kind: .shrimp, count: 2),
            ])
        case .mixed:
            return PondConfig(groups: [
                EntityGroup(kind: .koi, count: 5),
                EntityGroup(kind: .turtle, count: 1),
                EntityGroup(kind: .jellyfish, count: 2),
                EntityGroup(kind: .shrimp, count: 1),
                EntityGroup(kind: .duckweed, count: 4),
            ])
        case .lilyPond:
            return PondConfig(groups: [
                EntityGroup(kind: .koi, count: 6),
                EntityGroup(kind: .turtle, count: 1),
                EntityGroup(kind: .waterLily, count: 4, sizeMin: 0.8, sizeMax: 1.5),
                EntityGroup(kind: .duckweed, count: 8),
            ])
        }
    }
}
