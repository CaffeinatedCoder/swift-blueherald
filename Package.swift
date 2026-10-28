// swift-tools-version: 6.4
import PackageDescription

// Layers, from the bottom up:
//   BLEMCPCore           domain model, the BLECentral backend protocol and the BLESession actor; no platform I/O
//   BLEMCPCoreBluetooth  the Apple backend: a CBCentralManager bridged into an actor running on its own queue
//   BLEMCPReplay         the offline backend: plays a JSONL capture through the same seam; also diffs captures
//   BLEMCPServer         the MCP adapter: configuration, JSON schemas, tool registry and the tool catalogue
//   ble-mcp              composition root: reads the environment, wires the backend and serves over stdio
//
// Every module carries the BLEMCP prefix so this package can be linked next to device libraries
// such as swift-dragoman (DragomanCore, DragomanCoreBluetooth, DragomanTesting, ...) without
// module name clashes.

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "swift-ble-mcp",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ble-mcp", targets: ["ble-mcp"]),
        .library(name: "BLEMCPCore", targets: ["BLEMCPCore"]),
        .library(name: "BLEMCPCoreBluetooth", targets: ["BLEMCPCoreBluetooth"]),
        .library(name: "BLEMCPReplay", targets: ["BLEMCPReplay"]),
        .library(name: "BLEMCPServer", targets: ["BLEMCPServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "BLEMCPCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "BLEMCPCoreBluetooth",
            dependencies: ["BLEMCPCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "BLEMCPReplay",
            dependencies: ["BLEMCPCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "BLEMCPServer",
            dependencies: [
                "BLEMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "ble-mcp",
            dependencies: [
                "BLEMCPCore",
                "BLEMCPCoreBluetooth",
                "BLEMCPReplay",
                "BLEMCPServer",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["Info.plist"],
            swiftSettings: strictSettings,
            linkerSettings: [
                // A command-line tool has no bundle, so the Bluetooth usage description that macOS
                // privacy checks look for is embedded into the binary's __TEXT,__info_plist section.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", Context.packageDirectory + "/Sources/ble-mcp/Info.plist",
                ])
            ]
        ),

        .target(
            name: "BLEMCPTestSupport",
            dependencies: ["BLEMCPCore"],
            path: "Tests/BLEMCPTestSupport",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BLEMCPCoreTests",
            dependencies: ["BLEMCPCore", "BLEMCPTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            // Conversions only: nothing here creates a CBCentralManager or touches the radio.
            name: "BLEMCPCoreBluetoothTests",
            dependencies: ["BLEMCPCore", "BLEMCPCoreBluetooth"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BLEMCPReplayTests",
            dependencies: [
                "BLEMCPCore",
                "BLEMCPReplay",
                "BLEMCPServer",
                "BLEMCPTestSupport",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            // Runs the built ble-mcp executable as a child process; no Bluetooth is used.
            name: "BLEMCPCommandTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BLEMCPServerTests",
            dependencies: [
                "BLEMCPCore",
                "BLEMCPServer",
                "BLEMCPTestSupport",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)
