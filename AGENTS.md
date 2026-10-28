# swift-ble-mcp

A Bluetooth Low Energy MCP server for macOS in Swift 6 (`ble-mcp`). The [README](README.md) describes the tools, the configuration and the architecture; this file holds what an agent or contributor needs in order to change the code safely.

## Commands

```bash
swift build
swift test                                # no Bluetooth hardware needed
swift test -c release                     # the same, optimised
swift test --sanitize=thread
swift format lint --strict -r Sources Tests Scripts Package.swift
swift format -i -r Sources Tests Scripts Package.swift
```

Requires macOS 26 and Swift 6.2 or later. Done means all five checks above pass, plus the hardware check below when it applies.

## Hardware check

The tests run against `FakeCentral` (and `ReplayCentral`), so they cannot see `CoreBluetoothCentral`. After any change to `BLEMCPCoreBluetooth`, or to actor, continuation or cancellation code anywhere, build **release** and run the smoke script against a real peripheral:

```bash
swift build -c release
swift Scripts/hardware-smoke.swift --name <advertised name> --read 2A29,2A19
```

Debug builds have passed while release builds crashed. The script is read-only unless you pass `--transact`, which allows exactly one frame. Each rebuilt binary triggers the macOS Bluetooth permission prompt, which only a person can answer; a failing "scan finds the peripheral" step is usually the peripheral not advertising, not a bug. Never write to a characteristic you do not own: restrict writes with `BLE_MCP_WRITE_VALUE_ALLOWLIST` to exact frames.

## Layout and rules

```
ble-mcp              composition root: environment, logging, signals, stdio, `diff` subcommand
BLEMCPServer         MCP adapter: ToolArgument schemas, ToolDefinition catalogue, wire models
BLEMCPCoreBluetooth  BLECentral on CoreBluetooth
BLEMCPReplay         ReplayCentral and capture diff: a BLECentral that plays a JSONL capture
BLEMCPCore           domain model, BLECentral protocol, BLESession actor (no platform I/O)
```

- Dependencies point downwards only. `BLEMCPCore` imports nothing platform-specific and has no dependencies.
- Every module keeps the `BLEMCP` prefix so the package links next to swift-dragoman (`DragomanCore`, `DragomanCoreBluetooth`, `DragomanTesting`, ...). Never add a module name that collides with it.
- `BLESession` is an actor and actors are re-entrant: every method that suspends must re-validate its preconditions afterwards and claim capacity *before* awaiting.
- Pass isolation explicitly to `withTaskCancellationHandler(operation:onCancel:isolation:)` (`isolation: self`). The `nonisolated(nonsending)` overload loses the hop back to the actor in optimised builds on Swift 6.4 ([swiftlang/swift#92915](https://github.com/swiftlang/swift/issues/92915)). No actor-isolated closure may be converted to a caller-isolated one.
- Errors are typed (`throws(BLEError)`) and carry a stable snake_case `code` and, where there is a next step, a `hint`. A new failure gets a case, a code and a test, not a string.
- Tool arguments are declared once as a `ToolArgument`, which produces both the JSON schema and the parsing. Do not parse arguments by hand.
- Values are immutable, `Sendable` and typed; use phantom-typed identifiers rather than bare strings or UUIDs. Avoid `[String: Any]` and `JSONSerialization`. Justify any new dependency against performance, immutability and robustness.
- Newest language features first (Swift 6 mode, typed throws, `Synchronization`, upcoming features as enabled in `Package.swift`).

## Adding or changing a tool

1. Define it in `Sources/BLEMCPServer/Tools/` with `ToolArgument`s and register it in the catalogue.
2. A tool that writes must be hidden while writes are disabled and must pass the write policy before anything else happens.
3. Update the README tool table and the tool count in its first paragraph. Do not state a test count anywhere.
4. Cover it through MCP in `Tests/BLEMCPServerTests/EndToEndTests.swift` and in the core with `FakeCentral`.

## Device data is untrusted

Advertised names, 0x2901 descriptions and value text come from devices and end up in the model's context. Clean text where it enters the server (`DeviceText`), keep `hex` as the authoritative value, and keep telling the agent in the server instructions and tool descriptions that it is data, never instructions. A capture or replay file is device data too.

## Captures

`BLE_MCP_CAPTURE` writes JSONL that swift-dragoman's `CaptureLog` loads as a test fixture (`t`, `dir` of `tx`/`rx`/`info`, `uuid` in lowercase short form, lowercase `hex`, optional `note` and scalar marker fields). The format is a contract with that package: nested values in `info` rows are fine because `CaptureLog` skips them, but never rename or retype an existing field. Replays and `ble-mcp diff` must keep reading older captures. The README's "Capturing a session" and "Replaying a capture" sections are the specification.

## Style and commits

- `.swift-format` is authoritative (4 spaces, 140 columns). Run the formatter instead of arguing with it.
- Match the surrounding code's comment density: comments say why, not what.
- Commit subjects are imperative and say what changed for the user; the body says why, what was measured and which checks ran (debug, ThreadSanitizer, release, hardware). One concern per commit.
- Do not commit `.idea/`, `.index-build/` or `.claude/agent-memory-local/`.
