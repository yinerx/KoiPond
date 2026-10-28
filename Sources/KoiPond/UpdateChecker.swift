import AppKit
import PondCore

/// Checks GitHub Releases for a newer version; can download it, swap the app bundle and relaunch.
final class UpdateChecker {
    private let state: AppState
    private var busy = false

    /// "owner/repo", from Info.plist (KPUpdateRepo) so forks can point elsewhere.
    static var repo: String { Bundle.main.object(forInfoDictionaryKey: "KPUpdateRepo") as? String ?? "yinerx/KoiPond" }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev" }

    init(state: AppState) { self.state = state }

    func checkOnLaunchIfDue() {
        guard state.autoCheckUpdates, UpdateCheck.isDue(lastCheck: state.lastUpdateCheck) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.check(userInitiated: false) }
    }

    func check(userInitiated: Bool) {
        guard !busy, let url = UpdateCheck.latestReleaseURL(repo: UpdateChecker.repo) else { return }
        busy = true
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("KoiPond/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // The REST API allows 60 anonymous requests an hour per IP address; behind a shared address
            // (company network, VPN, carrier NAT) that is gone quickly and GitHub answers 403/429.
            // The website has no such quota, so fall back to it.
            if err == nil, UpdateCheck.shouldFallBack(status: code) {
                self.checkViaWebsite(userInitiated: userInitiated, apiStatus: code)
                return
            }
            DispatchQueue.main.async {
                self.busy = false
                self.state.lastUpdateCheck = Date()
                if let err { if userInitiated { self.info("检查更新失败", err.localizedDescription) }; return }
                if code == 404 { if userInitiated { self.info("还没有发布版本", "GitHub 上的 \(UpdateChecker.repo) 还没有正式发布。") }; return }
                guard code == 200, let data, let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    if userInitiated { self.info("检查更新失败", "GitHub 返回了 \(code)。稍后再试。") }
                    return
                }
                self.handle(rel, userInitiated: userInitiated)
            }
        }.resume()
    }

    /// Without the API: github.com/<repo>/releases/latest redirects to the newest release page (its URL
    /// carries the tag); the notes come from that tag's CHANGELOG.md; the download URL is GitHub's fixed pattern.
    private func checkViaWebsite(userInitiated: Bool, apiStatus: Int) {
        let repo = UpdateChecker.repo
        guard let page = UpdateCheck.latestReleasePage(repo: repo) else { finishFailed(userInitiated, apiStatus); return }
        var req = URLRequest(url: page, timeoutInterval: 20)
        req.httpMethod = "HEAD"
        req.setValue("KoiPond/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            guard err == nil, let final = resp?.url, let tag = UpdateCheck.tag(fromReleasePage: final) else {
                self.finishFailed(userInitiated, apiStatus, detail: err?.localizedDescription)
                return
            }
            let deliver: (String?) -> Void = { notes in
                DispatchQueue.main.async {
                    self.busy = false
                    self.state.lastUpdateCheck = Date()
                    guard let rel = GitHubRelease.fromWebsite(repo: repo, tag: tag, notes: notes) else { return }
                    self.handle(rel, userInitiated: userInitiated)
                }
            }
            guard let log = UpdateCheck.changelogURL(repo: repo, tag: tag) else { deliver(nil); return }
            URLSession.shared.dataTask(with: URLRequest(url: log, timeoutInterval: 15)) { data, r, _ in
                let ok = (r as? HTTPURLResponse)?.statusCode == 200
                let text = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
                deliver(text.flatMap { UpdateCheck.changelogSection($0, version: tag) })
            }.resume()
        }.resume()
    }

    private func finishFailed(_ userInitiated: Bool, _ apiStatus: Int, detail: String? = nil) {
        DispatchQueue.main.async {
            self.busy = false
            guard userInitiated else { return }
            self.info("检查更新失败",
                      "GitHub 暂时拒绝了查询（\(apiStatus)），改用网页查询也没有成功" + (detail.map { "：\($0)" } ?? "。") +
                      "\n\n可能是网络无法访问 github.com。也可以直接打开发布页查看：https://github.com/\(UpdateChecker.repo)/releases")
        }
    }

    private func handle(_ rel: GitHubRelease, userInitiated: Bool) {
        let result = UpdateCheck.evaluate(current: UpdateChecker.currentVersion, release: rel,
                                          skippedVersion: userInitiated ? nil : state.skippedVersion,
                                          includePrereleases: state.includePrereleases)
        switch result {
        case .upToDate:
            if userInitiated { info("已是最新版本", "当前版本 \(UpdateChecker.currentVersion)。") }
        case .skipped:
            break
        case .unusable(let why):
            if userInitiated { info("无法比较版本", why) }
        case .available(let v):
            offer(rel, version: v)
        }
    }

    private func offer(_ rel: GitHubRelease, version: SemVer) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "发现新版本 KoiPond \(version)"
        var notes = (rel.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        a.informativeText = "当前版本 \(UpdateChecker.currentVersion)。\n\n" + (notes.isEmpty ? "（没有更新说明）" : notes)
        let canInstall = rel.appAsset != nil && UpdateChecker.installableBundle != nil
        if canInstall { a.addButton(withTitle: "下载并安装") }
        a.addButton(withTitle: "查看发布页")
        a.addButton(withTitle: "跳过此版本")
        a.addButton(withTitle: "稍后")
        let r = a.runModal()
        let idx = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let actions = (canInstall ? ["install"] : []) + ["page", "skip", "later"]
        guard idx >= 0, idx < actions.count else { return }
        switch actions[idx] {
        case "install": if let asset = rel.appAsset { install(asset, fallback: rel.htmlURL) }
        case "page": NSWorkspace.shared.open(rel.htmlURL)
        case "skip": state.skippedVersion = version.description
        default: break
        }
    }

    /// The running .app, if it can be replaced in place.
    static var installableBundle: URL? {
        let b = Bundle.main.bundleURL
        guard b.pathExtension == "app", FileManager.default.isWritableFile(atPath: b.deletingLastPathComponent().path) else { return nil }
        return b
    }

    private func install(_ asset: GitHubRelease.Asset, fallback: URL) {
        guard let dest = UpdateChecker.installableBundle else { NSWorkspace.shared.open(fallback); return }
        // downloads in the background; the app restarts by itself when the new version is in place
        URLSession.shared.downloadTask(with: asset.browserDownloadURL) { tmp, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let tmp, err == nil, code == 200 else {
                DispatchQueue.main.async { self.info("下载失败", err?.localizedDescription ?? "HTTP \(code)"); NSWorkspace.shared.open(fallback) }
                return
            }
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("KoiPondUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tmp, to: zip)
                try UpdateChecker.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }) else { throw NSError(domain: "KoiPond", code: 1, userInfo: [NSLocalizedDescriptionKey: "压缩包里没有找到 KoiPond.app"]) }
                DispatchQueue.main.async { self.swapAndRelaunch(newApp: newApp, dest: dest) }
            } catch {
                DispatchQueue.main.async { self.info("安装失败", error.localizedDescription); NSWorkspace.shared.open(fallback) }
            }
        }.resume()
    }

    /// A tiny shell script waits for this process to quit, swaps the bundle, clears quarantine and opens the new app.
    private func swapAndRelaunch(newApp: URL, dest: URL) {
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(dest.path).old"
        mv "\(dest.path)" "\(dest.path).old" && mv "\(newApp.path)" "\(dest.path)" && rm -rf "\(dest.path).old"
        xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
        open "\(dest.path)"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("koipond-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [url.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            info("安装失败", error.localizedDescription)
        }
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "KoiPond", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) 失败（\(p.terminationStatus)）"])
        }
    }

    private func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
