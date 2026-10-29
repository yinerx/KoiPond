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

/// Holds the small update window and what its buttons do.
final class UpdateWindowController: NSObject, NSWindowDelegate {
    let session: UpdateSession
    private var window: NSWindow?
    var onRestart: ((URL) -> Void)?
    var onLater: ((URL) -> Void)?
    var onSkip: ((SemVer) -> Void)?
    var onClosed: (() -> Void)?

    init(session: UpdateSession) { self.session = session }

    func show() {
        if window == nil {
            let view = UpdateView(
                session: session,
                onRestart: { [weak self] in guard let self, let app = self.session.newApp else { return }; self.onRestart?(app) },
                onLater: { [weak self] in guard let self, let app = self.session.newApp else { return }; self.onLater?(app); self.close() },
                onSkip: { [weak self] in guard let self else { return }; self.session.cancel(); self.onSkip?(self.session.version); self.close() },
                onOpenPage: { [weak self] in guard let self else { return }; NSWorkspace.shared.open(self.session.release.htmlURL) },
                onClose: { [weak self] in self?.session.cancel(); self?.close() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
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
        // closing with the red button while downloading cancels; a finished download installs on quit
        if case .ready = session.phase, let app = session.newApp { onLater?(app) } else { session.cancel() }
        onClosed?()
    }
}
