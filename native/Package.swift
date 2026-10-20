// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIRS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIRSApp", targets: ["AIRSApp"]),
        .executable(name: "airs-entitlements", targets: ["AIRSEntitlementCLI"]),
        .library(name: "AIRSCore", targets: ["AIRSCore"]),
        .library(name: "AIRSEntitlements", targets: ["AIRSEntitlements"])
    ],
    dependencies: [.package(path: "Vendor/EntitlementDiff"),
                   .package(path: "Vendor/Lumen")],
    targets: [
        .executableTarget(name: "AIRSEntitlementCLI", dependencies: [
            "AIRSEntitlements",
            .product(name: "EntitlementDiffCLIKit", package: "EntitlementDiff"),
            .product(name: "EntitlementDiffSecurity", package: "EntitlementDiff")
        ]),
        .target(name: "AIRSCore"),
        .target(name: "AIRSEntitlements", dependencies: ["AIRSCore",
            .product(name: "EntitlementDiffCore", package: "EntitlementDiff"),
            .product(name: "EntitlementDiffSecurity", package: "EntitlementDiff")]),
        .executableTarget(
            name: "AIRSApp",
            dependencies: ["AIRSCore", "AIRSEntitlements",
                .product(name: "LumenTokens", package: "Lumen"),
                .product(name: "LumenUI", package: "Lumen"),
                .product(name: "EntitlementDiffCore", package: "EntitlementDiff"),
                .product(name: "EntitlementDiffModel", package: "EntitlementDiff"),
                .product(name: "EntitlementDiffSecurity", package: "EntitlementDiff")
            ]
        ),
        .testTarget(name: "AIRSAppTests", dependencies: ["AIRSApp"]),
        .testTarget(name: "AIRSEntitlementsTests", dependencies: ["AIRSEntitlements"]),
        .testTarget(
            name: "AIRSCoreTests",
            dependencies: ["AIRSCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
