import AppKit
import Combine
import PondCore

/// Checks GitHub Releases for a newer version. When there is one, a small window downloads it (with a
/// progress bar), verifies it, and offers "重新启动" — or installs it when KoiPond quits.
final class UpdateChecker {
    private let state: AppState
    private var busy = false
    private var updateWindow: UpdateWindowController?
    /// A verified update waiting for KoiPond to quit ("稍后").
    private var pendingInstall: URL?
    private var testBag: Set<AnyCancellable> = []

    /// "owner/repo", from Info.plist (KPUpdateRepo) so forks can point elsewhere.
    static var repo: String { Bundle.main.object(forInfoDictionaryKey: "KPUpdateRepo") as? String ?? "yinerx/KoiPond" }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev" }

    init(state: AppState) { self.state = state }

    // MARK: finding the newest release

    enum FetchFailure: Error {
        case noRelease
        case rejected(api: Int, detail: String?)   // API refused (403/429) and the website did not help either
        case http(Int)
        case network(String)
    }

    /// The newest release. Tries the REST API (full notes, asset sizes); when it answers 403/429 — 60 anonymous
    /// requests an hour per IP, quickly gone behind a shared address — falls back to the website, which has no
    /// quota: github.com/<repo>/releases/latest redirects to the release page, the notes come from that tag's
    /// CHANGELOG.md and the download URL follows GitHub's fixed pattern. Calls back on the main thread.
    func fetchLatest(_ done: @escaping (Result<GitHubRelease, FetchFailure>) -> Void) {
        let finish: (Result<GitHubRelease, FetchFailure>) -> Void = { r in DispatchQueue.main.async { done(r) } }
        guard let url = UpdateCheck.latestReleaseURL(repo: UpdateChecker.repo) else { finish(.failure(.noRelease)); return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("KoiPond/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err { finish(.failure(.network(err.localizedDescription))); return }
            if UpdateCheck.shouldFallBack(status: code) { self.fetchViaWebsite(apiStatus: code, finish); return }
            if code == 404 { finish(.failure(.noRelease)); return }
            guard code == 200, let data, let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                finish(.failure(.http(code))); return
            }
            finish(.success(rel))
        }.resume()
    }

    private func fetchViaWebsite(apiStatus: Int, _ finish: @escaping (Result<GitHubRelease, FetchFailure>) -> Void) {
        let repo = UpdateChecker.repo
        guard let page = UpdateCheck.latestReleasePage(repo: repo) else { finish(.failure(.rejected(api: apiStatus, detail: nil))); return }
        var req = URLRequest(url: page, timeoutInterval: 20)
        req.httpMethod = "HEAD"
        req.setValue("KoiPond/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            guard err == nil, let final = resp?.url, let tag = UpdateCheck.tag(fromReleasePage: final) else {
                finish(.failure(.rejected(api: apiStatus, detail: err?.localizedDescription))); return
            }
            let deliver: (String?) -> Void = { notes in
                guard let rel = GitHubRelease.fromWebsite(repo: repo, tag: tag, notes: notes) else {
                    finish(.failure(.rejected(api: apiStatus, detail: nil))); return
                }
                finish(.success(rel))
            }
            guard let log = UpdateCheck.changelogURL(repo: repo, tag: tag) else { deliver(nil); return }
            URLSession.shared.dataTask(with: URLRequest(url: log, timeoutInterval: 15)) { data, r, _ in
                let ok = (r as? HTTPURLResponse)?.statusCode == 200
                let text = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
                deliver(text.flatMap { UpdateCheck.changelogSection($0, version: tag) })
            }.resume()
        }.resume()
    }

    // MARK: checking

    func checkOnLaunchIfDue() {
        guard state.autoCheckUpdates, UpdateCheck.isDue(lastCheck: state.lastUpdateCheck) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.check(userInitiated: false) }
    }

    func check(userInitiated: Bool) {
        if let w = updateWindow { w.show(); return }     // a check or an update is already on screen
        guard !busy else { return }
        guard userInitiated else { checkQuietly(); return }
        // a manual check opens the window at once and shows the answer in it
        let flow = UpdateFlow(.checking)
        let c = makeController(flow)
        updateWindow = c
        c.show()
        run(in: flow)
    }

    /// Automatic checks stay silent; only a new version opens the window.
    private func checkQuietly() {
        busy = true
        fetchLatest { result in
            self.busy = false
            self.state.lastUpdateCheck = Date()
            guard case .success(let rel) = result,
                  case .available(let v) = UpdateCheck.evaluate(current: UpdateChecker.currentVersion, release: rel,
                                                                 skippedVersion: self.state.skippedVersion,
                                                                 includePrereleases: self.state.includePrereleases)
            else { return }
            let flow = UpdateFlow(.update(UpdateSession(release: rel, version: v, currentVersion: UpdateChecker.currentVersion)))
            let c = self.makeController(flow)
            self.updateWindow = c
            c.show()
        }
    }

    /// Asks GitHub and puts the answer into `flow`. The checking animation stays at least 0.8 s, so a fast
    /// answer does not just flash past.
    private func run(in flow: UpdateFlow) {
        busy = true
        flow.stage = .checking
        let started = Date()
        fetchLatest { result in
            let wait = max(0, 0.8 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                self.busy = false
                self.state.lastUpdateCheck = Date()
                guard self.updateWindow?.flow === flow else { return }   // the window was closed meanwhile
                flow.stage = self.stage(for: result)
            }
        }
    }

    private func stage(for result: Result<GitHubRelease, FetchFailure>) -> UpdateFlow.Stage {
        let current = UpdateChecker.currentVersion
        switch result {
        case .failure(let f): return .failed(message(for: f))
        case .success(let rel):
            switch UpdateCheck.evaluate(current: current, release: rel, includePrereleases: state.includePrereleases) {
            case .available(let v): return .update(UpdateSession(release: rel, version: v, currentVersion: current))
            case .upToDate, .skipped: return .upToDate(current)
            case .unusable(let why): return .failed("无法比较版本：\(why)")
            }
        }
    }

    private func message(for f: FetchFailure) -> String {
        switch f {
        case .noRelease: return "GitHub 上的 \(UpdateChecker.repo) 还没有正式发布。"
        case .http(let c): return "GitHub 返回了 \(c)。稍后再试。"
        case .network(let m): return "连不上 GitHub：\(m)"
        case .rejected(let api, let detail):
            return "GitHub 暂时拒绝了查询（\(api)），改用网页查询也没有成功" + (detail.map { "：\($0)" } ?? "。") +
                "可能是网络无法访问 github.com。"
        }
    }

    // MARK: the update window

    private func makeController(_ flow: UpdateFlow) -> UpdateWindowController {
        let c = UpdateWindowController(flow: flow)
        c.onRestart = { [weak self] app in self?.install(app, relaunch: true) }
        c.onLater = { [weak self] app in self?.pendingInstall = app }
        c.onSkip = { [weak self] v in self?.state.skippedVersion = v.description }
        c.onRetry = { [weak self, weak flow] in if let flow { self?.run(in: flow) } }
        c.onClosed = { [weak self] in self?.updateWindow = nil }
        return c
    }

    /// Called from applicationWillTerminate: a downloaded update the user put off goes in now.
    func installPendingOnQuit() {
        guard let app = pendingInstall else { return }
        pendingInstall = nil
        install(app, relaunch: false)
    }

    /// The running .app, if it can be replaced in place.
    static var installableBundle: URL? {
        let b = Bundle.main.bundleURL
        guard b.pathExtension == "app", FileManager.default.isWritableFile(atPath: b.deletingLastPathComponent().path) else { return nil }
        return b
    }

    /// A tiny shell script waits for this process to end, swaps the bundle, clears quarantine and (for a
    /// restart) opens the new app. The old bundle is only removed once the new one is in place.
    private func install(_ newApp: URL, relaunch: Bool) {
        guard let dest = UpdateChecker.installableBundle else { return }
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(dest.path).old"
        if mv "\(dest.path)" "\(dest.path).old" && mv "\(newApp.path)" "\(dest.path)"; then
          rm -rf "\(dest.path).old"
        else
          [ -d "\(dest.path)" ] || mv "\(dest.path).old" "\(dest.path)"
        fi
        xattr -dr com.apple.quarantine "\(dest.path)" 2>/dev/null
        \(relaunch ? "open \"\(dest.path)\"" : "")
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("koipond-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [url.path]
            try p.run()
            if relaunch { NSApp.terminate(nil) }
        } catch {
            info("安装失败", error.localizedDescription)
        }
    }

    // MARK: CI

    /// `KoiPond --test-update`: finds the newest release, downloads its app with the update window's code,
    /// unpacks and verifies it — everything but the swap. Prints progress, exits 0 on success.
    func runDownloadTest() {
        func say(_ s: String) { print(s); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { say("UPDATE TEST FAIL: timed out"); exit(1) }
        say("update test: asking GitHub for the newest release of \(UpdateChecker.repo)")
        // the real window, so its checking and download views are drawn on a real Mac too
        let flow = UpdateFlow(.checking)
        let window = makeController(flow)
        updateWindow = window
        window.show()
        fetchLatest { result in
            guard case .success(let rel) = result, let v = rel.version else {
                say("UPDATE TEST FAIL: could not find the newest release (\(result))"); exit(1)
            }
            say("update test: newest is \(rel.tagName), asset \(rel.appAsset?.name ?? "none")")
            let session = UpdateSession(release: rel, version: v, currentVersion: UpdateChecker.currentVersion)
            flow.stage = .update(session)
            var lastShown = -1
            session.$phase.sink { phase in
                switch phase {
                case .downloading(let p):
                    let pct = Int((p.fraction ?? 0) * 10)
                    if pct != lastShown { lastShown = pct; say("update test: downloading \(p.text)") }
                case .preparing: say("update test: unpacking and verifying")
                case .ready: say("update test: verified \(session.newApp?.path ?? "?")"); say("UPDATE TEST PASS"); exit(0)
                case .failed(let m): say("UPDATE TEST FAIL: \(m)"); exit(1)
                case .cannotInstall(let m): say("UPDATE TEST FAIL: \(m)"); exit(1)
                }
            }.store(in: &self.testBag)
            self.testSession = session
        }
    }
    private var testSession: UpdateSession?

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
