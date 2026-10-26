// swift-tools-version:5.9
import PackageDescription

// PondCore (simulation, config, update logic) is plain Swift and builds everywhere, so its tests run on Linux too.
// The renderer, the app and the screen saver need AppKit / Metal / ScreenSaver and only exist on macOS.
var products: [Product] = [
    .library(name: "PondCore", targets: ["PondCore"]),
]
var targets: [Target] = [
    .target(name: "PondCore"),
    .testTarget(name: "PondCoreTests", dependencies: ["PondCore"]),
]

#if os(macOS)
products += [
    .executable(name: "KoiPond", targets: ["KoiPond"]),
    .library(name: "PondSaver", type: .dynamic, targets: ["PondSaver"]),
]
targets += [
    .target(name: "PondRender", dependencies: ["PondCore"]),
    .executableTarget(name: "KoiPond", dependencies: ["PondCore", "PondRender"]),
    .target(name: "PondSaver", dependencies: ["PondCore", "PondRender"]),
]
#endif

let package = Package(
    name: "KoiPond",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
