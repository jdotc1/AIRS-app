// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EntitlementDiff",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EntitlementDiffCore", targets: ["EntitlementDiffCore"]),
        .library(name: "EntitlementDiffCLIKit", targets: ["EntitlementDiffCLIKit"]),
        .library(name: "EntitlementDiffModel", targets: ["EntitlementDiffModel"]),
        .library(name: "EntitlementDiffSecurity", targets: ["EntitlementDiffSecurity"])
    ],
    targets: [
        .target(name: "EntitlementDiffCore"),
        .target(name: "EntitlementDiffCLIKit", dependencies: ["EntitlementDiffCore"]),
        .target(name: "EntitlementDiffModel", dependencies: ["EntitlementDiffCore"]),
        .target(name: "EntitlementDiffSecurity", dependencies: ["EntitlementDiffCore"],
                linkerSettings: [.linkedFramework("Security")])
    ],
    swiftLanguageModes: [.v6]
)
