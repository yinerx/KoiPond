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
        public init(name: String, browserDownloadURL: URL, size: Int) { self.name = name; self.browserDownloadURL = browserDownloadURL; self.size = size }
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

    public init(tagName: String, name: String?, body: String?, htmlURL: URL, draft: Bool = false, prerelease: Bool = false, assets: [Asset]) {
        self.tagName = tagName; self.name = name; self.body = body; self.htmlURL = htmlURL
        self.draft = draft; self.prerelease = prerelease; self.assets = assets
    }

    /// A release described without the REST API (no rate limit): the tag comes from the redirect of
    /// github.com/<repo>/releases/latest, the download URL follows GitHub's fixed pattern, and the notes
    /// come from that tag's CHANGELOG.md.
    public static func fromWebsite(repo: String, tag: String, notes: String?) -> GitHubRelease? {
        guard let page = URL(string: "https://github.com/\(repo)/releases/tag/\(tag)") else { return nil }
        let v = SemVer(tag)?.description ?? tag
        let zip = "KoiPond-\(v).zip"
        let assets = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(zip)")
            .map { [Asset(name: zip, browserDownloadURL: $0, size: 0)] } ?? []
        return GitHubRelease(tagName: tag, name: "KoiPond \(v)", body: notes, htmlURL: page, assets: assets)
    }

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

    /// Website address that redirects to the newest (non-pre-release) release page — no API quota.
    public static func latestReleasePage(repo: String) -> URL? { URL(string: "https://github.com/\(repo)/releases/latest") }

    /// The tag in a release page URL: ".../releases/tag/v1.2.3" → "v1.2.3".
    public static func tag(fromReleasePage url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "tag"), i + 1 < parts.count, i > 0, parts[i - 1] == "releases" else { return nil }
        let t = parts[i + 1]
        return t.isEmpty ? nil : t
    }

    /// CHANGELOG.md of a tag, served without the API.
    public static func changelogURL(repo: String, tag: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(tag)/CHANGELOG.md")
    }

    /// The section of a changelog under "## v<version>" (up to the next "## v" heading).
    public static func changelogSection(_ text: String, version: String) -> String? {
        let want = "## v" + (SemVer(version)?.description ?? version)
        var out: [Substring] = [], inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## v") {
                if inside { break }
                inside = line.trimmingCharacters(in: .whitespaces) == want
                continue
            }
            if inside { out.append(line) }
        }
        let body = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// API answers that mean "try again without the API" (rate limited, or blocked for this address).
    public static func shouldFallBack(status: Int) -> Bool { status == 403 || status == 429 }

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
