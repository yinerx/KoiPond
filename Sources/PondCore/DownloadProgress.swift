import Foundation

/// Bytes downloaded so far, and how they read in the update window.
public struct DownloadProgress: Equatable, Sendable {
    public var received: Int64
    /// nil when the server does not say how big the file is.
    public var total: Int64?
    public init(received: Int64, total: Int64?) { self.received = received; self.total = total.flatMap { $0 > 0 ? $0 : nil } }

    /// 0…1, or nil when the size is unknown (the bar then just shows activity).
    public var fraction: Double? {
        guard let t = total else { return nil }
        return min(1, max(0, Double(received) / Double(t)))
    }

    /// "1.2 / 1.7 MB（70%）", or "1.2 MB" when the size is unknown.
    public var text: String {
        guard let t = total, let f = fraction else { return DownloadProgress.mb(received) }
        return "\(DownloadProgress.mb(received, unit: false)) / \(DownloadProgress.mb(t))（\(Int((f * 100).rounded(.down)))%）"
    }

    /// Megabytes with one decimal: 1_700_000 → "1.6 MB".
    public static func mb(_ bytes: Int64, unit: Bool = true) -> String {
        let s = String(format: "%.1f", Double(max(0, bytes)) / 1_048_576)
        return unit ? s + " MB" : s
    }
}

public extension UpdateCheck {
    /// A downloaded app is the expected update when its bundle identifier matches ours and its version is
    /// the one the release promised (so a wrong or truncated download is never installed).
    static func isExpectedUpdate(bundleID: String?, version: String?, expectedBundleID: String, expected: SemVer) -> Bool {
        guard bundleID == expectedBundleID, let v = version.flatMap(SemVer.init) else { return false }
        return v == expected
    }
}
