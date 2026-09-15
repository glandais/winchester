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
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["DiskCore"],
            path: "Tests/DiskCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // La couche défragmentation — plan de partition, volume en extents,
        // planificateur, simulateur mécanique — compilée ici pour être testée.
        //
        // Ces fichiers appartiennent à l'application, qui les compile de son
        // côté ; ce sont bien les mêmes, pas une copie. Les faire entrer dans un
        // module à part entière aurait demandé de rendre publique la moitié de
        // la couche pour la seule commodité des tests. La double compilation
        // coûte deux secondes ; ne rien pouvoir tester coûtait plus cher.
        .target(
            name: "DefragKit",
            dependencies: ["DiskCore"],
            path: "Sources/Model",
            exclude: ["Scenario.swift", "SimulationModel.swift", "DiskLibraryModel.swift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DefragKitTests",
            dependencies: ["DefragKit"],
            path: "Tests/DefragKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
