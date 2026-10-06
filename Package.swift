// swift-tools-version: 6.4
// SPDX-License-Identifier: MIT
import PackageDescription

var targets: [Target] = [
    .target(name: "BrightnessCore"),
    .target(name: "KeyboardCore", dependencies: ["BrightnessCore"]),
    .testTarget(name: "KeyboardCoreTests", dependencies: ["KeyboardCore"], path: "tests/KeyboardCoreTests"),
    .testTarget(name: "BrightnessCoreTests", dependencies: ["BrightnessCore"], path: "tests/BrightnessCoreTests"),
]
var products: [Product] = [.library(name: "BrightnessCore", targets: ["BrightnessCore"])]
#if os(Windows)
    targets += [
        .systemLibrary(name: "WindowsDisplayABI", path: "Sources/WindowsDisplayABI"),
        .executableTarget(
            name: "SwiftyToys", dependencies: ["BrightnessCore", "KeyboardCore", "WindowsDisplayABI"],
            linkerSettings: [
                .linkedLibrary("user32"), .linkedLibrary("gdi32"),
                .linkedLibrary("shell32"), .linkedLibrary("dxva2"), .linkedLibrary("hid"),
                .linkedLibrary("ole32"), .linkedLibrary("oleaut32"),
                .linkedLibrary("comctl32"), .linkedLibrary("advapi32"),
                .linkedLibrary("wtsapi32"), .linkedLibrary("setupapi"), .linkedLibrary("cfgmgr32"),
                .linkedLibrary("wevtapi"),
            ]),
    ]
    products.append(.executable(name: "SwiftyToys", targets: ["SwiftyToys"]))
#endif
let package = Package(
    name: "SwiftyToys", platforms: [.macOS(.v26)], products: products, targets: targets,
    swiftLanguageModes: [.v6])
