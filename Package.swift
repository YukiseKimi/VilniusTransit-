// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VilniusTransit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "VilniusTransitKit", targets: ["VilniusTransitKit"]),
        .library(name: "VilniusTransitUI", targets: ["VilniusTransitUI"]),
        .executable(name: "VilniusTransitApp", targets: ["VilniusTransitApp"]),
        .executable(name: "feedcheck", targets: ["feedcheck"]),
    ],
    targets: [
        .target(
            name: "VilniusTransitKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Everything the Mac and iPad apps share: model, map, markers, screens.
        // Builds for both platforms; only the drawing shim and a handful of
        // chrome affordances are conditional.
        .target(
            name: "VilniusTransitUI",
            dependencies: ["VilniusTransitKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "VilniusTransitApp",
            dependencies: ["VilniusTransitKit", "VilniusTransitUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "feedcheck",
            dependencies: ["VilniusTransitKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VilniusTransitKitTests",
            dependencies: ["VilniusTransitKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
