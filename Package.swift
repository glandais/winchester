// swift-tools-version: 6.0
import PackageDescription

// Noyau de simulation, isolé de l'application : ni SwiftUI, ni AVFAudio, ni
// Core Haptics. Il se construit et se teste en ligne de commande — `swift test`
// tourne en une poignée de secondes, là où un cycle par le simulateur iOS en
// coûte des dizaines — et c'est lui qui compile en concurrence stricte.
let package = Package(
    name: "DiskCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DiskCore", targets: ["DiskCore"]),
    ],
    targets: [
        .target(
            name: "DiskCore",
            path: "Sources/DiskCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["DiskCore"],
            path: "Tests/DiskCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
