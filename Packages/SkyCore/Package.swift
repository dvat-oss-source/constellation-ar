// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SkyCore",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(name: "SkyCore", targets: ["SkyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/heirloomlogic/AstronomyKit", exact: "4.1.0"),
        .package(url: "https://github.com/gavineadie/SatelliteKit", exact: "2.1.2"),
    ],
    targets: [
        .target(
            name: "SkyCore",
            dependencies: [
                .product(name: "AstronomyKit", package: "AstronomyKit"),
                .product(name: "SatelliteKit", package: "SatelliteKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SkyCoreTests",
            dependencies: ["SkyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
