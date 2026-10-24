// swift-tools-version: 6.0
import PackageDescription

// Module layout (each module is owned by one workstream so builds stay isolated):
//   CleanerKit       — shared models, safe removal, sizing, permissions. Everyone depends on it.
//   JunkEngine       — system junk scanning (caches, logs, dev junk, trash…).
//   UninstallEngine  — installed apps inventory, leftover discovery, full uninstall, orphans.
//   SpaceEngine      — old & large files analysis, disk space map.
//   HealthEngine     — read-only Mac health: battery, SSD, local snapshots, Intel-only apps, memory.
//   StartupEngine    — login items, launch agents and daemons: listing, disable/enable, removal.
//   ClearwiseMCPCore — the MCP server (JSON-RPC over stdio) that lets an AI assistant drive the engines.
//   MacCleaner       — SwiftUI app (executable); clearwise-mcp — the MCP server (executable).
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MacCleaner",
    defaultLocalization: "ru",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacCleaner", targets: ["MacCleaner"]),
        .executable(name: "clearwise-mcp", targets: ["ClearwiseMCP"]),
    ],
    targets: [
        .target(name: "CleanerKit", resources: [.process("Resources")], swiftSettings: swift5),
        .target(name: "JunkEngine", dependencies: ["CleanerKit"], resources: [.process("Resources")], swiftSettings: swift5),
        .target(name: "UninstallEngine", dependencies: ["CleanerKit"], resources: [.process("Resources")], swiftSettings: swift5),
        .target(name: "SpaceEngine", dependencies: ["CleanerKit"], resources: [.process("Resources")], swiftSettings: swift5),
        .target(name: "HealthEngine", dependencies: ["CleanerKit", "UninstallEngine"], swiftSettings: swift5),
        .target(name: "StartupEngine", dependencies: ["CleanerKit"], resources: [.process("Resources")], swiftSettings: swift5),
        .target(
            name: "ClearwiseMCPCore",
            dependencies: ["CleanerKit", "JunkEngine", "UninstallEngine", "SpaceEngine", "HealthEngine", "StartupEngine"],
            swiftSettings: swift5
        ),
        .executableTarget(name: "ClearwiseMCP", dependencies: ["ClearwiseMCPCore"], swiftSettings: swift5),
        .executableTarget(
            name: "MacCleaner",
            dependencies: ["CleanerKit", "JunkEngine", "UninstallEngine", "SpaceEngine", "HealthEngine", "StartupEngine"],
            resources: [.process("Resources")],
            swiftSettings: swift5
        ),
        .testTarget(name: "CleanerKitTests", dependencies: ["CleanerKit"], swiftSettings: swift5),
        .testTarget(name: "JunkEngineTests", dependencies: ["JunkEngine"], swiftSettings: swift5),
        .testTarget(name: "UninstallEngineTests", dependencies: ["UninstallEngine"], swiftSettings: swift5),
        .testTarget(name: "SpaceEngineTests", dependencies: ["SpaceEngine"], swiftSettings: swift5),
        .testTarget(name: "HealthEngineTests", dependencies: ["HealthEngine"], swiftSettings: swift5),
        .testTarget(name: "StartupEngineTests", dependencies: ["StartupEngine"], swiftSettings: swift5),
        .testTarget(name: "ClearwiseMCPTests", dependencies: ["ClearwiseMCPCore"], swiftSettings: swift5),
        .testTarget(name: "MacCleanerTests", dependencies: ["MacCleaner"], swiftSettings: swift5),
    ]
)
