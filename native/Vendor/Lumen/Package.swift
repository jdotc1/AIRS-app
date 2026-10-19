// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumenTokens", targets: ["LumenTokens"]),
        .library(name: "LumenUI", targets: ["LumenUI"])
    ],
    targets: [
        .target(name: "LumenTokens"),
        .target(name: "LumenUI", dependencies: ["LumenTokens"], resources: [.process("Resources")])
    ],
    swiftLanguageModes: [.v6]
)
