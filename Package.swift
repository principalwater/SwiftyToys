// swift-tools-version: 6.4
// SPDX-License-Identifier: MIT
import PackageDescription

var targets: [Target] = [
    .target(name: "BrightnessCore"),
    .target(name: "KeyboardCore", dependencies: ["BrightnessCore"]),
    .target(name: "SearchCore", dependencies: ["BrightnessCore"]),
    .testTarget(name: "SearchCoreTests", dependencies: ["SearchCore"], path: "tests/SearchCoreTests"),
    .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore"], path: "tests/KeyboardCoreTests"),
    .testTarget(name: "BrightnessCoreTests", dependencies: ["BrightnessCore"], path: "tests/BrightnessCoreTests"),
]
var products: [Product] = [.library(name: "BrightnessCore", targets: ["BrightnessCore"])]
#if os(Windows)
    targets += [
        .systemLibrary(name: "WindowsDisplayABI", path: "Sources/WindowsDisplayABI"),
        .systemLibrary(name: "SearchIndexABI", path: "Sources/SearchIndexABI"),
        .systemLibrary(name: "SearchXamlABI", path: "Sources/SearchXamlABI"),
        .systemLibrary(name: "EmbeddingABI", path: "Sources/EmbeddingABI"),
        .executableTarget(
            name: "SwiftyToys", dependencies: ["BrightnessCore", "KeyboardCore", "SearchCore", "WindowsDisplayABI", "SearchIndexABI", "SearchXamlABI", "EmbeddingABI"],
            linkerSettings: [
                .linkedLibrary("user32"), .linkedLibrary("gdi32"),
                .linkedLibrary("shell32"), .linkedLibrary("dxva2"), .linkedLibrary("hid"),
                .linkedLibrary("ole32"), .linkedLibrary("oleaut32"),
                .linkedLibrary("windowsapp"),
                .linkedLibrary("comctl32"), .linkedLibrary("advapi32"),
                .linkedLibrary("wtsapi32"), .linkedLibrary("setupapi"), .linkedLibrary("cfgmgr32"),
                .linkedLibrary("magnification"),
                .linkedLibrary("wevtapi"), .linkedLibrary("powrprof"),
                .linkedLibrary("winhttp"),
                .linkedLibrary("oleacc"), .linkedLibrary("shlwapi"),
                .linkedLibrary("bcrypt"), .linkedLibrary("wintrust"), .linkedLibrary("crypt32"),
            ]),
    ]
    products.append(.executable(name: "SwiftyToys", targets: ["SwiftyToys"]))
#endif
let package = Package(
    name: "SwiftyToys", platforms: [.macOS(.v26)], products: products, targets: targets,
    swiftLanguageModes: [.v6])
