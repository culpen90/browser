// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Browser", targets: ["BrowserApp"]),
        .library(name: "BrowserCore", targets: ["BrowserCore"])
    ],
    targets: [
        .target(name: "BrowserCore"),
        .executableTarget(name: "BrowserApp", dependencies: ["BrowserCore"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "BrowserAppTests", dependencies: ["BrowserApp"])
    ],
    swiftLanguageModes: [.v5]
)
