// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SklandusCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SklandusKit", targets: ["SklandusKit"]),
        .library(name: "SklandusUI", targets: ["SklandusUI"]),
    ],
    targets: [
        // Data and logic. No UI, so it can be tested without a host app.
        .target(
            name: "SklandusKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Everything both apps show. The app targets themselves stay thin.
        .target(
            name: "SklandusUI",
            dependencies: ["SklandusKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Diagnostics against the live server. Not part of either app.
        .executableTarget(
            name: "feedcheck",
            dependencies: ["SklandusKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SklandusUITests",
            dependencies: ["SklandusUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SklandusKitTests",
            dependencies: ["SklandusKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
