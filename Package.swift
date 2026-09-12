// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VilniusTransit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "VilniusTransitKit", targets: ["VilniusTransitKit"]),
        .executable(name: "VilniusTransitApp", targets: ["VilniusTransitApp"]),
        .executable(name: "feedcheck", targets: ["feedcheck"]),
    ],
    targets: [
        .target(
            name: "VilniusTransitKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "VilniusTransitApp",
            dependencies: ["VilniusTransitKit"],
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
