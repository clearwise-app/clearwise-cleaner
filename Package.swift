// swift-tools-version: 6.0
import PackageDescription

// Module layout (each module is owned by one workstream so builds stay isolated):
//   CleanerKit       — shared models, safe removal, sizing, permissions. Everyone depends on it.
//   JunkEngine       — system junk scanning (caches, logs, dev junk, trash…).
//   UninstallEngine  — installed apps inventory, leftover discovery, full uninstall, orphans.
//   SpaceEngine      — old & large files analysis, disk space map.
//   HealthEngine     — read-only Mac health: battery, SSD, local snapshots, Intel-only apps, memory.
//   StartupEngine    — login items, launch agents and daemons: listing, disable/enable, removal.
//   MacCleaner       — SwiftUI app (executable).
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacCleaner", targets: ["MacCleaner"]),
    ],
    targets: [
        .target(name: "CleanerKit", swiftSettings: swift5),
        .target(name: "JunkEngine", dependencies: ["CleanerKit"], swiftSettings: swift5),
        .target(name: "UninstallEngine", dependencies: ["CleanerKit"], swiftSettings: swift5),
        .target(name: "SpaceEngine", dependencies: ["CleanerKit"], swiftSettings: swift5),
        .target(name: "HealthEngine", dependencies: ["CleanerKit", "UninstallEngine"], swiftSettings: swift5),
        .target(name: "StartupEngine", dependencies: ["CleanerKit"], swiftSettings: swift5),
        .executableTarget(
            name: "MacCleaner",
            dependencies: ["CleanerKit", "JunkEngine", "UninstallEngine", "SpaceEngine", "HealthEngine", "StartupEngine"],
            swiftSettings: swift5
        ),
        .testTarget(name: "CleanerKitTests", dependencies: ["CleanerKit"], swiftSettings: swift5),
        .testTarget(name: "JunkEngineTests", dependencies: ["JunkEngine"], swiftSettings: swift5),
        .testTarget(name: "UninstallEngineTests", dependencies: ["UninstallEngine"], swiftSettings: swift5),
        .testTarget(name: "SpaceEngineTests", dependencies: ["SpaceEngine"], swiftSettings: swift5),
        .testTarget(name: "HealthEngineTests", dependencies: ["HealthEngine"], swiftSettings: swift5),
        .testTarget(name: "StartupEngineTests", dependencies: ["StartupEngine"], swiftSettings: swift5),
    ]
)
