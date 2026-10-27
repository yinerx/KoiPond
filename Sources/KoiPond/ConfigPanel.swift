import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PondCore

/// The configuration window: presets and global settings, the list of animal groups, and the selected group's details.
struct ConfigPanel: View {
    @ObservedObject var state: AppState
    let updater: UpdateChecker
    @State private var selection: Selection? = .global

    enum Selection: Hashable { case global, display, group(UUID) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("池塘") {
                    Label("全局设置", systemImage: "slider.horizontal.3").tag(Selection.global)
                    Label("显示与更新", systemImage: "macwindow.on.rectangle").tag(Selection.display)
                }
                Section("生物") {
                    ForEach(state.config.groups) { g in
                        HStack {
                            Text(KindIcon.symbol(g.kind)).frame(width: 18)
                            Text(g.name).foregroundStyle(g.enabled ? .primary : .secondary)
                            Spacer()
                            Text("\(g.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(Selection.group(g.id))
                        .contextMenu { Button("删除", role: .destructive) { remove(g.id) } }
                    }
                    .onMove { from, to in state.config.groups.move(fromOffsets: from, toOffset: to) }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        ForEach(EntityKind.allCases) { k in
                            Button("\(KindIcon.symbol(k))  \(k.displayName)") { add(k) }
                        }
                    } label: { Label("添加生物", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    if case .group(let id)? = selection {
                        Button { remove(id) } label: { Image(systemName: "minus") }.buttonStyle(.borderless).help("删除所选生物组")
                    }
                }
                .padding(8)
            }
        } detail: {
            switch selection {
            case .group(let id)?:
                if let idx = state.config.groups.firstIndex(where: { $0.id == id }) {
                    GroupEditor(group: $state.config.groups[idx])
                } else { placeholder }
            case .display?: DisplaySettings(state: state, updater: updater)
            default: GlobalEditor(state: state)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    var placeholder: some View { Text("在左侧选择一个生物组").foregroundStyle(.secondary) }

    func add(_ k: EntityKind) {
        let g = EntityGroup(kind: k)
        state.config.groups.append(g)
        selection = .group(g.id)
    }
    func remove(_ id: UUID) {
        state.config.groups.removeAll { $0.id == id }
        selection = .global
    }
}

enum KindIcon {
    static func symbol(_ k: EntityKind) -> String {
        switch k {
        case .koi: return "🐟"
        case .jellyfish: return "🪼"
        case .whale: return "🐋"
        case .squid: return "🦑"
        case .turtle: return "🐢"
        case .shrimp: return "🦐"
        case .duckweed: return "🍀"
        case .waterLily: return "🪷"
        }
    }
}

// MARK: - Global

struct GlobalEditor: View {
    @ObservedObject var state: AppState
    @State private var message: String?

    var body: some View {
        Form {
            Section("预设") {
                HStack {
                    ForEach(Preset.allCases) { p in Button(p.displayName) { state.load(preset: p) } }
                }
                HStack {
                    Button("导入配置…") { importJSON() }
                    Button("导出配置…") { exportJSON() }
                    Spacer()
                    if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("外观") {
                Picker("主题", selection: $state.config.global.theme) {
                    ForEach(Theme.allCases) { Text($0.displayName).tag($0) }
                }
                HexColorRow(title: "背景色", hex: $state.config.global.backgroundHex,
                            fallback: Palette.make(GlobalSettings()).background, allowsDefault: true)
                SliderRow(title: "字符格大小", value: $state.config.global.cellSize, range: 6...32, step: 1, format: "%.0f pt")
                SliderRow(title: "方块间隙", value: $state.config.global.tileGap, range: 0...6, step: 0.5, format: "%.1f pt")
                Toggle("阴影", isOn: $state.config.global.shadows)
                Toggle("显示计数（锦鲤 / 鱼饵）", isOn: $state.config.global.showCounter)
                Toggle("显示帧率", isOn: $state.config.global.showFPS)
            }
            Section("水与鱼饵") {
                SliderRow(title: "模拟速度", value: $state.config.global.simulationSpeed, range: 0...3, step: 0.05, format: "%.2f×")
                SliderRow(title: "涟漪强度", value: $state.config.global.rippleStrength, range: 0...3, step: 0.05, format: "%.2f")
                SliderRow(title: "涟漪持续", value: $state.config.global.rippleLifetime, range: 0.3...8, step: 0.1, format: "%.1f 秒")
                Stepper("每次点击撒饵：\(state.config.global.pelletsPerClick) 粒", value: $state.config.global.pelletsPerClick, in: 0...30)
                Stepper("鱼饵上限：\(state.config.global.maxPellets) 粒", value: $state.config.global.maxPellets, in: 0...200, step: 4)
                SliderRow(title: "鱼饵存在", value: $state.config.global.pelletLifetime, range: 1...120, step: 1, format: "%.0f 秒")
            }
        }
        .formStyle(.grouped)
    }

    func importJSON() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try state.importConfig(from: url); message = "已导入" } catch { message = "导入失败：\(error.localizedDescription)" }
    }
    func exportJSON() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "KoiPond 配置.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try state.exportConfig(to: url); message = "已导出" } catch { message = "导出失败：\(error.localizedDescription)" }
    }
}

// MARK: - Display & updates

struct DisplaySettings: View {
    @ObservedObject var state: AppState
    let updater: UpdateChecker
    @State private var saverMessage: String?

    var body: some View {
        Form {
            Section("显示形态") {
                Toggle("窗口", isOn: $state.windowMode)
                Toggle("桌面壁纸（铺在桌面图标下方）", isOn: $state.wallpaperMode)
                Toggle("壁纸模式下点击桌面空白处撒饵", isOn: $state.wallpaperClickFeeds).disabled(!state.wallpaperMode)
                Text("壁纸模式不需要任何系统权限：KoiPond 只在你点击桌面空白处时撒饵，点在其他窗口上不会触发。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("屏幕保护程序") {
                HStack {
                    Button("安装屏幕保护程序") { saverMessage = ScreenSaverInstaller.install(config: state.config) }
                    Button("把当前配置同步到屏保") { saverMessage = ScreenSaverInstaller.sync(config: state.config) }
                }
                if let m = saverMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                Text("点「安装」会弹出系统的安装窗口，装好后系统设置会跳到屏幕保护程序。屏保里的锦鲤会定时自动喂食。修改配置后点「同步」，屏保下次启动时生效。").font(.caption).foregroundStyle(.secondary)
            }
            Section("更新") {
                LabeledContent("当前版本", value: UpdateChecker.currentVersion)
                Toggle("启动时自动检查更新（每天最多一次）", isOn: $state.autoCheckUpdates)
                Toggle("包括预发布版本", isOn: $state.includePrereleases)
                Button("立即检查更新…") { updater.check(userInitiated: true) }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Group

struct GroupEditor: View {
    @Binding var group: EntityGroup

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(KindIcon.symbol(group.kind)).font(.title)
                    TextField("名称", text: $group.name).textFieldStyle(.roundedBorder)
                    Toggle("启用", isOn: $group.enabled).toggleStyle(.switch)
                }
                Stepper("数量：\(group.count)", value: $group.count, in: 0...group.kind.maxCount)
            }
            Section {
                SliderRow(title: "最小", value: $group.sizeMin, range: 0.2...4, step: 0.05, format: "%.2f×") { v in
                    if group.sizeMax < v { group.sizeMax = v }
                }
                SliderRow(title: "最大", value: $group.sizeMax, range: 0.2...4, step: 0.05, format: "%.2f×") { v in
                    if group.sizeMin > v { group.sizeMin = v }
                }
                Text("每一只的体型在最小和最大之间随机。1× ≈ \(Int(group.kind.baseLength)) pt 长。最小、最大设成一样，就是统一大小。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("体型") }
            if !group.kind.isPlant {
                Section("行为") {
                    SliderRow(title: "速度", value: $group.speed, range: 0...3, step: 0.05, format: "%.2f×")
                    SliderRow(title: "最浅", value: $group.depthMin, range: 0...1, step: 0.05, format: "%.2f") { v in
                        if group.depthMax < v { group.depthMax = v }
                    }
                    SliderRow(title: "最深", value: $group.depthMax, range: 0...1, step: 0.05, format: "%.2f") { v in
                        if group.depthMin > v { group.depthMin = v }
                    }
                    Toggle("可喂食", isOn: Binding(get: { group.kind.canBeFed && group.feedable },
                                                set: { group.feedable = $0 && group.kind.canBeFed }))
                        .disabled(!group.kind.canBeFed)
                    if !group.kind.canBeFed { Text("只有锦鲤会吃鱼饵。").font(.caption).foregroundStyle(.secondary) }
                }
            }
            KindSection(group: $group)
        }
        .formStyle(.grouped)
    }
}

struct KindSection: View {
    @Binding var group: EntityGroup
    var body: some View {
        switch group.kind {
        case .koi:
            Section("锦鲤") {
                SliderRow(title: "好奇心", value: $group.params.curiosity, range: 0...1, step: 0.05, format: "%.2f")
                SliderRow(title: "觅食范围", value: $group.params.foodRange, range: 50...1500, step: 10, format: "%.0f pt")
                SliderRow(title: "胆小程度", value: $group.params.startleSensitivity, range: 0...1, step: 0.05, format: "%.2f")
                Text("品种比例").font(.subheadline)
                ForEach(KoiVariety.allCases) { v in
                    SliderRow(title: v.displayName, value: Binding(get: { group.params.varieties[v.rawValue] ?? 0 },
                                                                  set: { group.params.varieties[v.rawValue] = $0 }),
                              range: 0...10, step: 1, format: "%.0f")
                }
            }
        case .jellyfish:
            Section("水母") {
                SliderRow(title: "脉动频率", value: $group.params.pulseRate, range: 0.1...2, step: 0.05, format: "%.2f 次/秒")
                SliderRow(title: "触须长度", value: $group.params.tentacleLength, range: 0.2...3, step: 0.1, format: "%.1f×")
                SliderRow(title: "不透明度", value: $group.params.opacity, range: 0.1...1, step: 0.05, format: "%.2f")
                HexColorRow(title: "颜色", hex: $group.params.hue, fallback: RGBA(0xe6, 0xb3, 0xf0), allowsDefault: false)
            }
        case .whale:
            Section("鲸鱼") { SliderRow(title: "喷水间隔", value: $group.params.spoutInterval, range: 4...90, step: 1, format: "%.0f 秒") }
        case .squid:
            Section("乌贼") {
                SliderRow(title: "喷射频率", value: $group.params.jetRate, range: 0.05...2, step: 0.05, format: "%.2f 次/秒")
                Toggle("受惊时喷墨", isOn: $group.params.inkEnabled)
            }
        case .turtle:
            Section("乌龟") { SliderRow(title: "换气间隔", value: $group.params.surfaceInterval, range: 4...90, step: 1, format: "%.0f 秒") }
        case .shrimp:
            Section("虾群") {
                Stepper("每群 \(group.params.perSchool) 只", value: $group.params.perSchool, in: 3...80)
                Text("「数量」是虾群的个数。").font(.caption).foregroundStyle(.secondary)
            }
        case .duckweed:
            Section("浮萍") { Stepper("每簇 \(group.params.clusterSize) 片叶子", value: $group.params.clusterSize, in: 3...60) }
        case .waterLily:
            Section("睡莲") { SliderRow(title: "开花概率", value: $group.params.flowerChance, range: 0...1, step: 0.05, format: "%.2f") }
        }
    }
}

// MARK: - Controls

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var onChange: ((Double) -> Void)? = nil

    var body: some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { value = $0; onChange?($0) }), in: range, step: step)
            Text(String(format: format, value)).monospacedDigit().frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
        }
    }
}

struct HexColorRow: View {
    let title: String
    @Binding var hex: String
    let fallback: RGBA
    let allowsDefault: Bool

    var body: some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { let c = RGBA(hex: hex) ?? fallback
                    return Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255) },
                set: { color in
                    guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                    hex = RGBA(UInt8(ns.redComponent * 255), UInt8(ns.greenComponent * 255), UInt8(ns.blueComponent * 255)).hex
                }), supportsOpacity: false)
            if allowsDefault && !hex.isEmpty { Button("恢复默认") { hex = "" }.buttonStyle(.link) }
        }
    }
}
