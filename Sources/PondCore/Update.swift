import Foundation

/// Semantic version: "1.2.3", "v1.2", "1.0.0-beta.2". Pre-releases sort before the release.
public struct SemVer: Comparable, CustomStringConvertible, Sendable {
    public var major: Int, minor: Int, patch: Int
    public var prerelease: [String]

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }   // build metadata is ignored
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts { guard let n = Int(p), n >= 0 else { return nil }; nums.append(n) }
        while nums.count < 3 { nums.append(0) }
        self.init(nums[0], nums[1], nums[2], prerelease: pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }
    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true      // numeric identifiers sort first
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
    public static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

/// The parts of GitHub's "release" object the updater uses.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int
        enum CodingKeys: String, CodingKey { case name, size, browserDownloadURL = "browser_download_url" }
    }
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey { case name, body, draft, prerelease, assets, tagName = "tag_name", htmlURL = "html_url" }

    public var version: SemVer? { SemVer(tagName) }

    /// The app download: "KoiPond-<version>.zip" (not the separate screen-saver archive).
    public var appAsset: Asset? {
        assets.first { $0.name.hasPrefix("KoiPond-") && $0.name.hasSuffix(".zip") && !$0.name.contains("Saver") }
    }
}

public enum UpdateCheck {
    public enum Result: Equatable, Sendable {
        case upToDate
        case available(SemVer)
        case skipped(SemVer)       // newer, but the user chose to skip this one
        case unusable(String)      // draft, unparsable tag…
    }

    public static func evaluate(current: String, release: GitHubRelease, skippedVersion: String? = nil,
                                includePrereleases: Bool = false) -> Result {
        guard let cur = SemVer(current) else { return .unusable("当前版本号无法识别：\(current)") }
        guard !release.draft else { return .unusable("草稿版本") }
        guard let new = release.version else { return .unusable("无法识别的版本标签：\(release.tagName)") }
        if (release.prerelease || new.isPrerelease) && !includePrereleases { return .upToDate }
        guard new > cur else { return .upToDate }
        if let s = skippedVersion, let sv = SemVer(s), sv == new { return .skipped(new) }
        return .available(new)
    }

    /// GitHub REST endpoint for the newest release of `owner/repo`.
    public static func latestReleaseURL(repo: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    }

    /// True when a scheduled automatic check is due (at most once per `interval` seconds).
    public static func isDue(lastCheck: Date?, now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        guard let l = lastCheck else { return true }
        return now.timeIntervalSince(l) >= interval
    }
}
