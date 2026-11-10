// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Portal-High-Bitrate",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Portal-High-Bitrate", targets: ["PortalHighBitrate"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "PortalHighBitrate",
            dependencies: [],
            path: "Sources/PortalHighBitrate",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
