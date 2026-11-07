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
        .target(name: "BrowserLLMKernels"),
        .target(name: "BrowserLLM", dependencies: ["BrowserLLMKernels"]),
        .executableTarget(name: "BrowserApp", dependencies: ["BrowserCore", "BrowserLLM"]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "BrowserAppTests", dependencies: ["BrowserApp", "BrowserLLM"])
    ],
    swiftLanguageModes: [.v5]
)
