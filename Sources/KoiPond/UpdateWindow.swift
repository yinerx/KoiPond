import AppKit
import SwiftUI
import PondCore

/// One update, from download to restart. Downloads as soon as it is created, verifies what arrived
/// (bundle identifier and version must match the release), then waits for "重新启动" — or installs when
/// KoiPond quits, if the user chose "稍后".
final class UpdateSession: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum Phase: Equatable {
        case downloading(DownloadProgress)
        case preparing                      // unzipping and checking
        case ready                          // verified, waiting for a restart
        case failed(String)
        case cannotInstall(String)          // e.g. not running from a writable .app
    }

    let release: GitHubRelease
    let version: SemVer
    let currentVersion: String
    @Published private(set) var phase: Phase
    private(set) var newApp: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var workDir: URL?

    init(release: GitHubRelease, version: SemVer, currentVersion: String) {
        self.release = release
        self.version = version
        self.currentVersion = currentVersion
        if release.appAsset == nil {
            phase = .cannotInstall("这个版本的发布页里没有 KoiPond 的安装包，请到发布页手动下载。")
        } else if UpdateChecker.installableBundle == nil {
            phase = .cannotInstall("KoiPond 没有放在可以替换的位置（例如「应用程序」文件夹），无法自动安装。请到发布页手动下载。")
        } else {
            phase = .downloading(DownloadProgress(received: 0, total: nil))
        }
        super.init()
        if case .downloading = phase { start() }
    }

    var notes: String {
        let n = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "（这个版本没有更新说明）" : n
    }

    // MARK: download

    func start() {
        guard let asset = release.appAsset else { return }
        cleanup()
        phase = .downloading(DownloadProgress(received: 0, total: asset.size > 0 ? Int64(asset.size) : nil))
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        var req = URLRequest(url: asset.browserDownloadURL, timeoutInterval: 60)
        req.setValue("KoiPond/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let t = s.downloadTask(with: req)
        session = s
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil; session = nil
        cleanup()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let known: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (release.appAsset?.size).flatMap { $0 > 0 ? Int64($0) : nil }
        phase = .downloading(DownloadProgress(received: totalBytesWritten, total: known))
    }

    /// The file at `location` is deleted when this returns, so it is moved out first; unzipping and the
    /// checks then run off the main thread.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { phase = .failed("下载失败：GitHub 返回了 \(code)。"); return }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("KoiPondUpdate-\(UUID().uuidString)", isDirectory: true)
        let zip = work.appendingPathComponent("update.zip")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: zip)
        } catch {
            phase = .failed("保存下载文件失败：\(error.localizedDescription)")
            return
        }
        workDir = work
        phase = .preparing
        let expected = version
        DispatchQueue.global(qos: .userInitiated).async {
            let result = UpdateSession.unpackAndVerify(zip: zip, into: work, expected: expected)
            DispatchQueue.main.async {
                switch result {
                case .success(let app): self.newApp = app; self.phase = .ready
                case .failure(let e): self.phase = .failed(e.localizedDescription)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        self.session = nil; self.task = nil
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        phase = .failed("下载失败：\(error.localizedDescription)")
    }

    /// Unzips the archive and makes sure it holds KoiPond at the promised version.
    static func unpackAndVerify(zip: URL, into dir: URL, expected: SemVer) -> Result<URL, Error> {
        do {
            try UpdateChecker.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("下载的压缩包里没有找到 KoiPond.app。")
            }
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            let id = info?["CFBundleIdentifier"] as? String, v = info?["CFBundleShortVersionString"] as? String
            let ours = Bundle.main.bundleIdentifier ?? "io.github.yinerx.koipond"
            guard UpdateCheck.isExpectedUpdate(bundleID: id, version: v, expectedBundleID: ours, expected: expected) else {
                throw UpdateError("下载的文件和预期不符（\(id ?? "?") \(v ?? "?")，应为 \(expected)），没有安装。")
            }
            return .success(app)
        } catch {
            return .failure(error)
        }
    }

    private func cleanup() {
        if let w = workDir { try? FileManager.default.removeItem(at: w) }
        workDir = nil
        newApp = nil
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - The window

struct UpdateView: View {
    @ObservedObject var session: UpdateSession
    var onRestart: () -> Void
    var onLater: () -> Void
    var onSkip: () -> Void
    var onOpenPage: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("KoiPond \(session.version.description) 可以更新了").font(.headline)
                    Text("当前版本 \(session.currentVersion)").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(session.notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 110)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            status
        }
        .padding(18)
        .frame(width: 440)
    }

    @ViewBuilder var status: some View {
        switch session.phase {
        case .downloading(let p):
            VStack(alignment: .leading, spacing: 6) {
                if let f = p.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                Text("正在下载… \(p.text)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Button("跳过此版本", action: onSkip)
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
            }
        case .preparing:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                Text("正在解压并核对新版本…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Text("下载完成。重新启动 KoiPond 即完成更新。").font(.callout)
            HStack {
                Button("稍后（退出时安装）", action: onLater)
                Spacer()
                Button("重新启动", action: onRestart).keyboardShortcut(.defaultAction)
            }
        case .failed(let msg):
            Text(msg).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("打开发布页", action: onOpenPage)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Button("重试") { session.start() }.keyboardShortcut(.defaultAction)
            }
        case .cannotInstall(let msg):
            Text(msg).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("跳过此版本", action: onSkip)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Button("打开发布页", action: onOpenPage).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - One window for the whole check

/// What the update window shows: checking first, then the answer.
final class UpdateFlow: ObservableObject {
    enum Stage {
        case checking
        case upToDate(String)          // current version
        case failed(String)
        case update(UpdateSession)
    }
    @Published var stage: Stage
    init(_ stage: Stage) { self.stage = stage }
}

struct UpdateFlowView: View {
    @ObservedObject var flow: UpdateFlow
    var onRestart: () -> Void
    var onLater: () -> Void
    var onSkip: () -> Void
    var onOpenPage: () -> Void
    var onRetry: () -> Void
    var onClose: () -> Void

    var body: some View {
        switch flow.stage {
        case .checking:
            CheckingView(onCancel: onClose)
        case .upToDate(let v):
            ResultView(symbol: "checkmark.circle.fill", tint: .green, title: "已是最新版本",
                       detail: "KoiPond \(v) 是目前最新的版本。") {
                Spacer()
                Button("好", action: onClose).keyboardShortcut(.defaultAction)
            }
        case .failed(let msg):
            ResultView(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "检查更新失败", detail: msg) {
                Button("打开发布页", action: onOpenPage)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Button("重试", action: onRetry).keyboardShortcut(.defaultAction)
            }
        case .update(let session):
            UpdateView(session: session, onRestart: onRestart, onLater: onLater, onSkip: onSkip,
                       onOpenPage: onOpenPage, onClose: onClose)
        }
    }
}

struct CheckingView: View {
    var onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            if reduceMotion {
                ProgressView().controlSize(.large).frame(width: 160, height: 96)
            } else {
                PondCheckingAnimation().frame(width: 160, height: 96)
            }
            Text("正在检查更新…").font(.headline)
            Text("正在向 GitHub 查询 KoiPond 的最新版本").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

struct ResultView<Buttons: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack { buttons() }
        }
        .padding(18)
        .frame(width: 440)
    }
}

/// A tiny pond while we wait: a pellet in the middle, character ripples spreading from it,
/// and a little tile koi circling. Drawn only while the window is on screen.
struct PondCheckingAnimation: View {
    private let water = Color(red: 0x1b / 255, green: 0x1a / 255, blue: 0x19 / 255)
    private let ripple = Color(red: 0x8f / 255, green: 0x8b / 255, blue: 0x85 / 255)
    private let pellet = Color(red: 0xd8 / 255, green: 0x8a / 255, blue: 0x3c / 255)
    private let body_ = Color(red: 0x9e / 255, green: 0x9a / 255, blue: 0x94 / 255)
    private let red = Color(red: 0xb4 / 255, green: 0x3e / 255, blue: 0x1c / 255)

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(water))
                let glyphFont = Font.system(size: 9, weight: .medium, design: .monospaced)
                // three ripple rings, each spreading and fading, staggered
                for k in 0..<3 {
                    let phase = (t / 1.8 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let r = 7 + phase * 46, alpha = (1 - phase) * 0.9
                    let n = max(8, Int(2 * Double.pi * r / 7))
                    for i in 0..<n {
                        let a = Double(i) / Double(n) * 2 * Double.pi
                        let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r * 0.6)
                        let g = Character(UnicodeScalar(Glyph.line(angle: atan2(cos(a) * 0.6, -sin(a)))))
                        ctx.draw(Text(String(g)).font(glyphFont).foregroundColor(ripple.opacity(alpha)), at: p)
                    }
                }
                ctx.draw(Text("o").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(pellet), at: c)
                // a little koi of four tiles circling the pellet, head first
                for j in 0..<4 {
                    let a = t * 1.5 - Double(j) * 0.26
                    let p = CGPoint(x: c.x + cos(a) * 52, y: c.y + sin(a) * 28)
                    let tile = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                    ctx.fill(Path(roundedRect: tile, cornerRadius: 1), with: .color(j == 1 || j == 2 ? red : body_))
                }
            }
        }
    }
}

/// Holds the update window and what its buttons do. The same window goes from "checking" to the answer.
final class UpdateWindowController: NSObject, NSWindowDelegate {
    let flow: UpdateFlow
    private var window: NSWindow?
    var onRestart: ((URL) -> Void)?
    var onLater: ((URL) -> Void)?
    var onSkip: ((SemVer) -> Void)?
    var onRetry: (() -> Void)?
    var onClosed: (() -> Void)?

    init(flow: UpdateFlow) { self.flow = flow }

    var session: UpdateSession? { if case .update(let s) = flow.stage { return s }; return nil }

    func show() {
        if window == nil {
            let view = UpdateFlowView(
                flow: flow,
                onRestart: { [weak self] in guard let self, let app = self.session?.newApp else { return }; self.onRestart?(app) },
                onLater: { [weak self] in guard let self, let app = self.session?.newApp else { return }; self.onLater?(app); self.close() },
                onSkip: { [weak self] in
                    guard let self, let s = self.session else { return }
                    s.cancel(); self.onSkip?(s.version); self.close()
                },
                onOpenPage: { [weak self] in
                    let url = self?.session?.release.htmlURL ?? URL(string: "https://github.com/\(UpdateChecker.repo)/releases")!
                    NSWorkspace.shared.open(url)
                },
                onRetry: { [weak self] in
                    guard let self else { return }
                    if let s = self.session { s.start() } else { self.onRetry?() }
                },
                onClose: { [weak self] in self?.session?.cancel(); self?.close() })
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]      // the window follows the content as it changes
            let w = NSWindow(contentViewController: host)
            w.title = "软件更新"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // closing while downloading cancels; a finished download installs on quit
        if let s = session {
            if case .ready = s.phase, let app = s.newApp { onLater?(app) } else { s.cancel() }
        }
        onClosed?()
    }
}
