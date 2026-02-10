// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ScreenHero",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ScreenHeroCore",
            targets: ["ScreenHeroCore"]
        ),
        .executable(
            name: "ScreenHeroHost",
            targets: ["ScreenHeroHost"]
        ),
        .executable(
            name: "ScreenHeroViewer",
            targets: ["ScreenHeroViewer"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ScreenHeroCore",
            dependencies: [],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ScreenHeroHost",
            dependencies: ["ScreenHeroCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "ScreenHeroViewer",
            dependencies: ["ScreenHeroCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ScreenHeroCoreTests",
            dependencies: ["ScreenHeroCore"]
        ),
        .testTarget(
            name: "PerformanceTests",
            dependencies: ["ScreenHeroCore"]
        ),
        .testTarget(
            name: "ScreenHeroHostTests",
            dependencies: ["ScreenHeroHost"]
        ),
    ]
)
