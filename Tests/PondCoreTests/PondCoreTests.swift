import XCTest
@testable import PondCore

final class SemVerTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(SemVer("v1.2.3")?.description, "1.2.3")
        XCTAssertEqual(SemVer("1.2")?.description, "1.2.0")
        XCTAssertEqual(SemVer("2.0.0-beta.2+build5")?.description, "2.0.0-beta.2")
        XCTAssertNil(SemVer("latest"))
        XCTAssertNil(SemVer("1.2.3.4"))
        XCTAssertNil(SemVer(""))
    }

    func testOrdering() {
        let order = ["0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0", "1.0.1", "1.1.0", "10.0.0"]
        let vs = order.compactMap(SemVer.init)
        XCTAssertEqual(vs.count, order.count)
        for i in 1..<vs.count { XCTAssertLessThan(vs[i - 1], vs[i], "\(vs[i - 1]) < \(vs[i])") }
        XCTAssertEqual(SemVer("v1.0"), SemVer("1.0.0"))
    }
}

final class UpdateTests: XCTestCase {
    func release(_ tag: String, pre: Bool = false, draft: Bool = false) throws -> GitHubRelease {
        let json = """
        {"tag_name":"\(tag)","name":"KoiPond \(tag)","body":"notes","html_url":"https://github.com/yinerx/KoiPond/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(pre),
         "assets":[{"name":"KoiPond-Saver-1.1.0.zip","browser_download_url":"https://example.com/s.zip","size":10},
                   {"name":"KoiPond-1.1.0.zip","browser_download_url":"https://example.com/a.zip","size":20}]}
        """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testDecision() throws {
        XCTAssertEqual(UpdateCheck.evaluate(current: "1.0.0", release: try release("v1.1.0")), .available(SemVer(1, 1, 0)))
        XCTAssertEqual(UpdateCheck.evaluate(current: "1.1.0", release: try release("v1.1.0")), .upToDate)
        XCTAssertEqual(UpdateCheck.evaluate(current: "1.2.0", release: try release("v1.1.0")), .upToDate)
        XCTAssertEqual(UpdateCheck.evaluate(current: "1.0.0", release: try release("v1.1.0"), skippedVersion: "1.1.0"), .skipped(SemVer(1, 1, 0)))
        XCTAssertEqual(UpdateCheck.evaluate(current: "1.0.0", release: try release("v1.1.0-beta.1", pre: true)), .upToDate)
        XCTAssertEqual(UpdateCheck.evaluate(current: "1.0.0", release: try release("v1.1.0-beta.1", pre: true), includePrereleases: true),
                       .available(SemVer("1.1.0-beta.1")!))
        if case .unusable = UpdateCheck.evaluate(current: "1.0.0", release: try release("nightly")) {} else { XCTFail("tag should be unusable") }
    }

    func testAssetChoice() throws {
        XCTAssertEqual(try release("v1.1.0").appAsset?.name, "KoiPond-1.1.0.zip")
    }

    func testSchedule() {
        let now = Date()
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
    }
}

final class ConfigTests: XCTestCase {
    func testRoundTrip() throws {
        for p in Preset.allCases {
            let c = p.config
            XCTAssertEqual(try PondConfig.decode(try c.encoded()), c.sanitized(), p.displayName)
        }
    }

    func testPartialJSONGetsDefaults() throws {
        let json = #"{"groups":[{"kind":"koi","count":3,"sizeMax":2.5},{"kind":"jellyfish","feedable":true}]}"#
        let c = try PondConfig.decode(Data(json.utf8))
        XCTAssertEqual(c.global.cellSize, 12)
        XCTAssertEqual(c.groups.count, 2)
        XCTAssertEqual(c.groups[0].count, 3)
        XCTAssertEqual(c.groups[0].sizeMax, 2.5)
        XCTAssertEqual(c.groups[0].params.foodRange, KindParams().foodRange)
        XCTAssertFalse(c.groups[1].feedable, "only koi can be fed")
    }

    func testSanitize() {
        var g = EntityGroup(kind: .whale, count: 50)
        g.sizeMin = 9; g.sizeMax = 0.01; g.depthMin = 0.8; g.depthMax = 0.1
        let s = g.sanitized()
        XCTAssertEqual(s.count, EntityKind.whale.maxCount)
        XCTAssertLessThanOrEqual(s.sizeMin, s.sizeMax)
        XCTAssertLessThanOrEqual(s.depthMin, s.depthMax)
        var gl = GlobalSettings(); gl.cellSize = 1000
        XCTAssertEqual(gl.sanitized().cellSize, 32)
    }
}

final class WorldTests: XCTestCase {
    func run(_ w: World, seconds: Double) { for _ in 0..<Int(seconds * 60) { w.tick(World.step) } }

    func testEveryKindSpawnsStepsAndDraws() {
        let groups = EntityKind.allCases.map { EntityGroup(kind: $0, count: 1) }
        let w = World(config: PondConfig(groups: groups), width: 1200, height: 800, seed: 7)
        XCTAssertEqual(w.creatures.count, EntityKind.allCases.count)
        w.feed(at: Vec2(600, 400))
        run(w, seconds: 5)
        let grid = CellGrid(width: 1200, height: 800, cellSize: 12)
        w.draw(into: grid)
        let used = grid.cells.filter { $0.glyph != Glyph.space || $0.bg.a > 0 }.count
        XCTAssertGreaterThan(used, 200, "the pond should show something")
        for c in w.creatures {
            XCTAssertTrue(c.position.x.isFinite && c.position.y.isFinite, "\(c.kind) left the number line")
        }
    }

    func testKoiComeForFood() {
        var g = EntityGroup(kind: .koi, count: 6)
        g.params.curiosity = 1
        let w = World(config: PondConfig(groups: [g]), width: 900, height: 600, seed: 3)
        w.feed(at: Vec2(450, 300))
        XCTAssertGreaterThan(w.pelletCount, 0)
        run(w, seconds: 25)
        XCTAssertGreaterThan(w.eaten, 0, "koi should have eaten something")
    }

    func testOnlyKoiEat() {
        var g = EntityGroup(kind: .jellyfish, count: 6)
        g.feedable = true      // must be ignored
        let s = EntityGroup(kind: .squid, count: 3), t = EntityGroup(kind: .turtle, count: 2)
        let w = World(config: PondConfig(groups: [g, s, t]), width: 900, height: 600, seed: 5)
        w.feed(at: Vec2(450, 300))
        run(w, seconds: 10)
        XCTAssertEqual(w.eaten, 0)
    }

    func testFeedableSwitchStopsKoi() {
        var g = EntityGroup(kind: .koi, count: 6)
        g.feedable = false; g.params.curiosity = 1
        let w = World(config: PondConfig(groups: [g]), width: 900, height: 600, seed: 3)
        w.feed(at: Vec2(450, 300))
        run(w, seconds: 12)
        XCTAssertEqual(w.eaten, 0)
    }

    func testSizeSetsBodyLength() {
        var small = EntityGroup(kind: .koi, count: 4); small.sizeMin = 0.5; small.sizeMax = 0.5
        var big = EntityGroup(kind: .koi, count: 4); big.sizeMin = 2; big.sizeMax = 2
        let w = World(config: PondConfig(groups: [small, big]), width: 1500, height: 1000, seed: 9)
        let koi = w.creatures.compactMap { $0 as? Koi }
        let lens = Dictionary(grouping: koi, by: { $0.groupID }).mapValues { $0.map(\.length) }
        XCTAssertEqual(lens[small.id]!.first!, EntityKind.koi.baseLength * 0.5, accuracy: 0.01)
        XCTAssertEqual(lens[big.id]!.first!, EntityKind.koi.baseLength * 2, accuracy: 0.01)
    }

    func testLiveCountChangeKeepsIndividuals() {
        var g = EntityGroup(kind: .koi, count: 3)
        let w = World(config: PondConfig(groups: [g]), width: 900, height: 600, seed: 1)
        // hold a strong reference: a freed object's address can be reused by its replacement
        let first = w.creatures[0]
        g.count = 5
        w.apply(config: PondConfig(groups: [g]))
        XCTAssertEqual(w.creatures.count, 5)
        XCTAssertTrue(w.creatures[0] === first, "existing koi stay")
        g.speed = 2       // behaviour-only change: nobody respawns
        w.apply(config: PondConfig(groups: [g]))
        XCTAssertTrue(w.creatures[0] === first)
        g.sizeMax = 2     // look change: the group respawns
        w.apply(config: PondConfig(groups: [g]))
        XCTAssertFalse(w.creatures.contains { $0 === first }, "the group was respawned")
        g.enabled = false
        w.apply(config: PondConfig(groups: [g]))
        XCTAssertEqual(w.creatures.count, 0)
    }

    func testPelletLimits() {
        var gl = GlobalSettings(); gl.maxPellets = 10; gl.pelletsPerClick = 6
        let w = World(config: PondConfig(global: gl, groups: []), width: 500, height: 500, seed: 2)
        w.feed(at: Vec2(100, 100)); w.feed(at: Vec2(200, 200)); w.feed(at: Vec2(300, 300))
        XCTAssertEqual(w.pelletCount, 10)
    }

    func testLineGlyphs() {
        XCTAssertEqual(Glyph.line(angle: 0), UInt8(ascii: "-"))
        XCTAssertEqual(Glyph.line(angle: .pi / 2), UInt8(ascii: "|"))
        XCTAssertEqual(Glyph.line(angle: .pi / 4), UInt8(ascii: "\\"))
        XCTAssertEqual(Glyph.line(angle: -.pi / 4), UInt8(ascii: "/"))
    }
}

final class SettingsPaneTests: XCTestCase {
    typealias C = SettingsPane.Candidate
    func testPrefersTheScreenSaverPage() {
        let panes = [C(identifier: "com.apple.Wallpaper-Settings.extension", name: "Wallpaper"),
                     C(identifier: "com.apple.Displays-Settings.extension", name: "Displays"),
                     C(identifier: "com.apple.ScreenSaver-Settings.extension", name: "Screen Saver")]
        XCTAssertEqual(SettingsPane.screenSaver(in: panes)?.identifier, "com.apple.ScreenSaver-Settings.extension")
    }
    func testMatchesByLocalizedNameWhenTheIdentifierChanged() {
        let panes = [C(identifier: "com.apple.settings.Desktop", name: "墙纸"),
                     C(identifier: "com.apple.settings.Idle", name: "屏幕保护程序")]
        XCTAssertEqual(SettingsPane.screenSaver(in: panes)?.identifier, "com.apple.settings.Idle")
    }
    func testFallsBackToWallpaper() {
        let panes = [C(identifier: "com.apple.Wallpaper-Settings.extension", name: "Wallpaper"),
                     C(identifier: "com.apple.Sound-Settings.extension", name: "Sound")]
        XCTAssertEqual(SettingsPane.screenSaver(in: panes)?.identifier, "com.apple.Wallpaper-Settings.extension")
    }
    func testNothingSuitable() {
        XCTAssertNil(SettingsPane.screenSaver(in: [C(identifier: "com.apple.Sound-Settings.extension", name: "Sound")]))
        XCTAssertEqual(SettingsPane.url(for: C(identifier: "com.apple.X", name: ""))?.absoluteString, "x-apple.systempreferences:com.apple.X")
    }
}

final class PowerTests: XCTestCase {
    func testProfiles() {
        for p in PowerProfile.allCases {
            XCTAssertLessThanOrEqual(p.calmFPS, p.activeFPS)
            XCTAssertGreaterThan(p.resolutionScale, 0)
        }
        XCTAssertLessThan(PowerProfile.saver.calmFPS, PowerProfile.balanced.calmFPS)
        XCTAssertLessThan(PowerProfile.balanced.calmFPS, PowerProfile.smooth.calmFPS)
        XCTAssertEqual(PowerProfile.smooth.effective(lowPowerMode: true, thermalSerious: false), .saver)
        XCTAssertEqual(PowerProfile.balanced.effective(lowPowerMode: false, thermalSerious: true), .saver)
        XCTAssertEqual(PowerProfile.balanced.effective(lowPowerMode: false, thermalSerious: false), .balanced)
    }

    func testCalmPondRunsSlowFeedingRunsFast() {
        var g = EntityGroup(kind: .koi, count: 4); g.params.curiosity = 1
        let w = World(config: PondConfig(groups: [g]), width: 1000, height: 700, seed: 8)
        for _ in 0..<(60 * 5) { w.tick(World.step) }
        let hold = PowerProfile.balanced.activeHold
        XCTAssertFalse(w.wantsFastFrames(hold: hold), "nothing happening: calm frame rate")
        w.feed(at: Vec2(500, 350))
        w.tick(World.step)
        XCTAssertTrue(w.wantsFastFrames(hold: hold), "food and ripples: fast frame rate")
        // once the food is gone and the water is still again, it calms down
        for _ in 0..<(60 * 40) { w.tick(World.step) }
        XCTAssertFalse(w.wantsFastFrames(hold: hold))
    }
}

final class CoverageTests: XCTestCase {
    typealias R = Coverage.Rect
    let screen = R(x: 0, y: 0, w: 1920, h: 1080)
    func testFullscreenWindowCovers() {
        XCTAssertTrue(Coverage.isCovered(screen, by: [R(x: 0, y: 0, w: 1920, h: 1080)]))
    }
    func testMenuBarPlusZoomedWindowCovers() {
        XCTAssertTrue(Coverage.isCovered(screen, by: [R(x: 0, y: 0, w: 1920, h: 25), R(x: 0, y: 25, w: 1920, h: 1055)]))
    }
    func testAStripOfDesktopShowing() {
        XCTAssertFalse(Coverage.isCovered(screen, by: [R(x: 0, y: 0, w: 1700, h: 1080)]))
        XCTAssertFalse(Coverage.isCovered(screen, by: []))
    }
    func testWindowsOnAnotherScreenDoNotCount() {
        let second = R(x: 1920, y: 0, w: 1440, h: 900)
        XCTAssertFalse(Coverage.isCovered(second, by: [R(x: 0, y: 0, w: 1920, h: 1080)]))
        XCTAssertTrue(Coverage.isCovered(second, by: [R(x: 1900, y: -20, w: 1500, h: 1000)]))
    }
}

final class CoverageFilterTests: XCTestCase {
    func testOnlyAppWindowsCanHideTheWallpaper() {
        XCTAssertTrue(Coverage.counts(layer: 0, alpha: 1), "app windows, full-screen apps")
        XCTAssertFalse(Coverage.counts(layer: 20, alpha: 1), "the Dock's transparent full-screen window")
        XCTAssertFalse(Coverage.counts(layer: 24, alpha: 1), "menu bar")
        XCTAssertFalse(Coverage.counts(layer: 25, alpha: 1), "Control Center, Spotlight")
        XCTAssertFalse(Coverage.counts(layer: 0, alpha: 0.2), "a faded window")
    }
    /// The window list a macOS runner reported: menu bar strips, the Dock over the whole screen, one app window.
    func testRunnerWindowListLeavesTheWallpaperVisible() {
        let screen = Coverage.Rect(x: 0, y: 0, w: 1024, h: 768)
        let list: [(Int, Coverage.Rect)] = [
            (25, .init(x: 803, y: 0, w: 31, h: 24)), (24, .init(x: 0, y: 0, w: 1024, h: 24)),
            (20, .init(x: 0, y: 0, w: 1024, h: 768)), (0, .init(x: 100, y: 40, w: 900, h: 628)),
        ]
        let counted = list.filter { Coverage.counts(layer: $0.0, alpha: 1) }.map { $0.1 }
        XCTAssertFalse(Coverage.isCovered(screen, by: counted))
        XCTAssertTrue(Coverage.isCovered(screen, by: counted + [.init(x: 0, y: 0, w: 1024, h: 768)]), "a full-screen app does hide it")
    }
}

final class UpdateFallbackTests: XCTestCase {
    func testTagFromRedirect() {
        XCTAssertEqual(UpdateCheck.tag(fromReleasePage: URL(string: "https://github.com/yinerx/KoiPond/releases/tag/v0.2.2")!), "v0.2.2")
        XCTAssertNil(UpdateCheck.tag(fromReleasePage: URL(string: "https://github.com/yinerx/KoiPond/releases")!), "no release yet")
        XCTAssertNil(UpdateCheck.tag(fromReleasePage: URL(string: "https://github.com/login")!))
    }
    func testChangelogSection() {
        let log = "# 更新日志\n\n## v0.2.2\n\n- 修复 A\n- 修复 B\n\n## v0.2.1\n\n- 旧的\n"
        XCTAssertEqual(UpdateCheck.changelogSection(log, version: "v0.2.2"), "- 修复 A\n- 修复 B")
        XCTAssertEqual(UpdateCheck.changelogSection(log, version: "0.2.1"), "- 旧的")
        XCTAssertNil(UpdateCheck.changelogSection(log, version: "9.9.9"))
    }
    func testReleaseFromWebsiteIsInstallable() {
        let r = GitHubRelease.fromWebsite(repo: "yinerx/KoiPond", tag: "v0.3.0", notes: "notes")!
        XCTAssertEqual(r.appAsset?.browserDownloadURL.absoluteString, "https://github.com/yinerx/KoiPond/releases/download/v0.3.0/KoiPond-0.3.0.zip")
        XCTAssertEqual(UpdateCheck.evaluate(current: "0.2.2", release: r), .available(SemVer(0, 3, 0)))
        XCTAssertTrue(UpdateCheck.shouldFallBack(status: 403))
        XCTAssertTrue(UpdateCheck.shouldFallBack(status: 429))
        XCTAssertFalse(UpdateCheck.shouldFallBack(status: 404))
    }
}

final class RasterizeTests: XCTestCase {
    struct Hit: Equatable { var c: Int, r: Int, s: Double, v: Double, inside: Bool }

    /// The previous algorithm: every cell of the bounding box against every segment.
    func reference(_ sp: Spine, _ g: CellGrid, pad: Double, maxWidth: Double, width: (Double) -> Double) -> [Hit] {
        var lo = sp.nodes[0], hi = sp.nodes[0]
        for p in sp.nodes { lo = Vec2(min(lo.x, p.x), min(lo.y, p.y)); hi = Vec2(max(hi.x, p.x), max(hi.y, p.y)) }
        let m = maxWidth + pad + g.cellSize
        let (c0, r0) = g.cellOf(lo - Vec2(m, m)), (c1, r1) = g.cellOf(hi + Vec2(m, m))
        guard let span = g.clip(cols: c0, c1, rows: r0, r1) else { return [] }
        var out: [Hit] = []
        for r in span.rows { for c in span.cols {
            let pr = sp.project(g.center(c, r))
            let w = max(0.5, width(pr.s)), d = abs(pr.lateral)
            if d <= w + pad { out.append(Hit(c: c, r: r, s: pr.s, v: pr.lateral / w, inside: d <= w)) }
        } }
        return out
    }

    func testSameCellsAsTheOldAlgorithm() {
        var rng = PondRandom(seed: 42)
        let g = CellGrid(width: 900, height: 600, cellSize: 12)
        var checked = 0
        for trial in 0..<200 {
            // random swimmers anywhere, including half off screen, bent by following a wiggly path
            let L = rng.range(40, 600), maxW = L * rng.range(0.06, 0.16)
            var sp = Spine(head: Vec2(rng.range(-100, 1000), rng.range(-100, 700)), heading: rng.angle(),
                           count: [6, 16, 22][trial % 3], length: L)
            var h = sp.head, ang = rng.angle()
            for _ in 0..<80 { ang += rng.range(-0.4, 0.4); h += Vec2.polar(ang, 6); sp.follow(h) }
            let width: (Double) -> Double = { s in maxW * (s < 0.2 ? 0.5 + 2.5 * s : 1.05 - s) }
            let pad = trial % 2 == 0 ? 10.8 : 0
            var got: [Hit] = []
            sp.rasterize(g, pad: pad, maxWidth: maxW, width: width) { c, r, s, v, inside in got.append(Hit(c: c, r: r, s: s, v: v, inside: inside)) }
            let want = reference(sp, g, pad: pad, maxWidth: maxW, width: width)
            XCTAssertEqual(got.count, want.count, "trial \(trial)")
            for (a, b) in zip(got, want) {
                XCTAssertEqual(a.c, b.c); XCTAssertEqual(a.r, b.r); XCTAssertEqual(a.inside, b.inside)
                XCTAssertEqual(a.s, b.s, accuracy: 1e-9); XCTAssertEqual(a.v, b.v, accuracy: 1e-9)
            }
            checked += want.count
        }
        XCTAssertGreaterThan(checked, 10_000, "the comparison must cover plenty of cells")
    }
}

final class DownloadProgressTests: XCTestCase {
    func testText() {
        XCTAssertEqual(DownloadProgress(received: 1_258_291, total: 1_782_579).text, "1.2 / 1.7 MB（70%）")
        XCTAssertEqual(DownloadProgress(received: 1_782_579, total: 1_782_579).text, "1.7 / 1.7 MB（100%）")
        XCTAssertEqual(DownloadProgress(received: 524_288, total: nil).text, "0.5 MB")
        XCTAssertNil(DownloadProgress(received: 10, total: 0).fraction, "a zero length means unknown")
        XCTAssertEqual(DownloadProgress(received: 900, total: 600).fraction, 1, "never past the end")
    }
    func testExpectedUpdate() {
        let id = "io.github.yinerx.koipond"
        XCTAssertTrue(UpdateCheck.isExpectedUpdate(bundleID: id, version: "0.4.0", expectedBundleID: id, expected: SemVer(0, 4, 0)))
        XCTAssertFalse(UpdateCheck.isExpectedUpdate(bundleID: id, version: "0.3.0", expectedBundleID: id, expected: SemVer(0, 4, 0)), "older build in the zip")
        XCTAssertFalse(UpdateCheck.isExpectedUpdate(bundleID: "com.other.app", version: "0.4.0", expectedBundleID: id, expected: SemVer(0, 4, 0)))
        XCTAssertFalse(UpdateCheck.isExpectedUpdate(bundleID: id, version: nil, expectedBundleID: id, expected: SemVer(0, 4, 0)))
    }
}
