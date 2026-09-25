// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Drafter",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DrafterCore"),
        .executableTarget(name: "Drafter", dependencies: ["DrafterCore"]),
        .testTarget(name: "DrafterCoreTests", dependencies: ["DrafterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
