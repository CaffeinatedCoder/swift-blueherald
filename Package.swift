// swift-tools-version: 6.4
import PackageDescription

// Layers, from the bottom up:
//   BlueHeraldCore           domain model, the BLECentral backend protocol and the BLESession actor; no platform I/O
//   BlueHeraldCoreBluetooth  the Apple backend: a CBCentralManager bridged into an actor running on its own queue
//   BlueHeraldReplay         the offline backend: plays a JSONL capture through the same seam; also diffs captures
//   BlueHeraldMCP            the MCP adapter: configuration, JSON schemas, tool registry and the tool catalogue
//   blueherald               composition root: reads the environment, wires the backend and serves over stdio
//
// Every module carries the BlueHerald prefix so this package can be linked next to device libraries
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
    // Every remaining unsafe construct is marked `unsafe` at its use, with a comment saying why.
    .strictMemorySafety(),
]

let package = Package(
    name: "swift-blueherald",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "blueherald", targets: ["blueherald"]),
        .library(name: "BlueHeraldCore", targets: ["BlueHeraldCore"]),
        .library(name: "BlueHeraldCoreBluetooth", targets: ["BlueHeraldCoreBluetooth"]),
        .library(name: "BlueHeraldReplay", targets: ["BlueHeraldReplay"]),
        .library(name: "BlueHeraldMCP", targets: ["BlueHeraldMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "BlueHeraldCore",
            swiftSettings: strictSettings
        ),
        .target(
            name: "BlueHeraldCoreBluetooth",
            dependencies: ["BlueHeraldCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "BlueHeraldReplay",
            dependencies: ["BlueHeraldCore"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "BlueHeraldMCP",
            dependencies: [
                "BlueHeraldCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "blueherald",
            dependencies: [
                "BlueHeraldCore",
                "BlueHeraldCoreBluetooth",
                "BlueHeraldReplay",
                "BlueHeraldMCP",
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
                    "-Xlinker", Context.packageDirectory + "/Sources/blueherald/Info.plist",
                ])
            ]
        ),

        .target(
            name: "BlueHeraldTestSupport",
            dependencies: ["BlueHeraldCore"],
            path: "Tests/BlueHeraldTestSupport",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BlueHeraldCoreTests",
            dependencies: ["BlueHeraldCore", "BlueHeraldTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            // Conversions only: nothing here creates a CBCentralManager or touches the radio.
            name: "BlueHeraldCoreBluetoothTests",
            dependencies: ["BlueHeraldCore", "BlueHeraldCoreBluetooth"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BlueHeraldReplayTests",
            dependencies: [
                "BlueHeraldCore",
                "BlueHeraldReplay",
                "BlueHeraldMCP",
                "BlueHeraldTestSupport",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            // Runs the built blueherald executable as a child process; no Bluetooth is used.
            name: "BlueHeraldCommandTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BlueHeraldMCPTests",
            dependencies: [
                "BlueHeraldCore",
                "BlueHeraldMCP",
                "BlueHeraldTestSupport",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)
