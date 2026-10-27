# swift-ble-mcp

A Bluetooth Low Energy [Model Context Protocol](https://modelcontextprotocol.io) server for macOS, written in Swift 6. It lets an AI agent scan for BLE devices, connect, explore their GATT tables, read and write characteristics and stream notifications, all through 17 typed MCP tools.

It is inspired by [es617/ble-mcp-server](https://github.com/es617/ble-mcp-server) and [Hypijump31/bluetooth-mcp-server](https://github.com/Hypijump31/bluetooth-mcp-server), and built natively on CoreBluetooth and the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk).

## Quick start

```bash
swift build -c release
claude mcp add ble -- "$PWD/.build/release/ble-mcp"
```

Then ask your agent something like *"Scan for BLE devices and read the battery level of the strongest one."*

The server is **read-only by default**. To let the agent write to devices:

```bash
claude mcp add ble -e BLE_MCP_ALLOW_WRITES=1 -e BLE_MCP_WRITE_ALLOWLIST=6E400002-B5A3-F393-E0A9-E50E24DCCA9E -- "$PWD/.build/release/ble-mcp"
```

For other clients, launch `ble-mcp` as a stdio server and pass the variables below as its environment.

### Bluetooth permission

The first BLE operation triggers the macOS prompt *"ble-mcp would like to use Bluetooth"*. Accept it. Until you do, tools fail with `bluetooth_unavailable` and a hint.

macOS normally attributes a command-line tool's privacy permissions to the app that launched it. If that app (Claude, an IDE) has no Bluetooth usage description, macOS kills the tool outright. `ble-mcp` therefore relaunches itself once at startup as its own "responsible process", so the permission belongs to `ble-mcp` regardless of the launcher. Set `BLE_MCP_OWN_PERMISSION=0` to turn this off.

Development builds are ad-hoc signed, so each rebuild is a new identity to macOS and may ask again.

## Tools

| Tool | Does |
|---|---|
| `ble_status` | Adapter state, write policy, limits, every open scan, connection and subscription |
| `ble_scan` | Blocking scan with filters (`name`, `service_uuids`, `min_rssi`, `manufacturer_id`, `connectable_only`); `stop_after` returns as soon as enough matches are found |
| `ble_scan_start` / `ble_scan_results` / `ble_scan_stop` | Background scans that run while the agent does other work |
| `ble_connect` / `ble_disconnect` / `ble_connections` | Connections; connecting discovers the full attribute table by default |
| `ble_discover` | Services, characteristics (with properties) and descriptors, with names for well-known UUIDs |
| `ble_read` / `ble_read_descriptor` | Values as hex, plus UTF-8 text when printable |
| `ble_write` / `ble_write_descriptor` | Only listed when writes are enabled; `value` in hex, base64 or utf8 |
| `ble_subscribe` / `ble_unsubscribe` | Notifications and indications into a bounded per-subscription buffer |
| `ble_notifications` | Drains buffered values in arrival order across subscriptions; `wait_ms` blocks until data arrives instead of polling |
| `ble_rssi` | Signal strength of a connected peripheral |

Every argument is declared once, as a `ToolArgument`. The same declaration produces the JSON schema and does the parsing, so the two cannot drift. Parsing is lenient about encoding: `5000`, `5000.0` and `"5000"` are the same integer, and UUIDs may be `2a19`, `0x2A19` or the full form. Meaning is checked strictly: unknown arguments, fractional or out-of-range numbers and malformed UUIDs are rejected with a message naming the argument.

Failures come back as tool results with `isError: true` and a body like:

```json
{"error":{"code":"ambiguous_characteristic","message":"Characteristic FFE1 exists in several services: FFE0, FFF0.","hint":"Pass service_uuid to choose one."}}
```

Disconnects and adapter changes are also pushed as MCP log notifications, for clients that show them.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BLE_MCP_ALLOW_WRITES` | off | `1`/`true`/`yes` enables the write tools |
| `BLE_MCP_WRITE_ALLOWLIST` | all | Comma-separated characteristic UUIDs that may be written; descriptor writes are checked against their characteristic |
| `BLE_MCP_MAX_CONNECTIONS` | 4 | Simultaneous connections (1–32) |
| `BLE_MCP_MAX_SUBSCRIPTIONS` | 32 | Active subscriptions (1–512) |
| `BLE_MCP_MAX_SCANS` | 4 | Concurrent background scans (1–16) |
| `BLE_MCP_NOTIFICATION_BUFFER` | 1024 | Values kept per subscription; the oldest are dropped first and counted |
| `BLE_MCP_CONNECT_TIMEOUT_MS` | 15000 | Connection timeout |
| `BLE_MCP_OPERATION_TIMEOUT_MS` | 10000 | Read, write, subscribe and RSSI timeout |
| `BLE_MCP_LOG_LEVEL` | warning | stderr log level; `info` logs every tool call with its duration |
| `BLE_MCP_OWN_PERMISSION` | 1 | See [Bluetooth permission](#bluetooth-permission) |

An invalid value stops the server at startup with a message naming the variable. It is never silently replaced by a default. Run `ble-mcp --help` for the same list.

## Architecture

```
ble-mcp              composition root: environment, logging, signals, stdio
BLEMCPServer         MCP adapter: ToolArgument schemas, ToolDefinition catalogue, wire models
BLEMCPCoreBluetooth  BLECentral on CoreBluetooth
BLEMCPCore           domain model, BLECentral protocol, BLESession actor (no platform I/O)
```

- **`BLESession`** (actor) owns all state: scans, connections, subscriptions and their ring buffers. Everything leaves it as immutable snapshot values. Because actors are re-entrant, every method that suspends re-validates its preconditions afterwards and claims capacity *before* awaiting, so concurrent calls cannot overshoot a limit.
- **`BLECentral`** is the backend seam: CoreBluetooth in production, a scripted `FakeCentral` in tests, BlueZ on Linux some day. Its contract is that every operation honours cancellation. The session enforces all timeouts in one place by racing the operation against a deadline in a task group.
- **`CoreBluetoothCentral`** is an actor whose executor *is* CoreBluetooth's dispatch queue. Delegate callbacks enter it synchronously through `assumeIsolated`, with no locks and no hops. `CBPeripheral` calls run on the queue CoreBluetooth expects, and the non-`Sendable` CoreBluetooth objects never leave the actor. Pending requests are continuations in FIFO tables keyed by object identity, and each one is removed before it is resumed, so a callback, a timeout and a disconnect racing for the same request resume it exactly once. A single radio scan is shared by any number of scan consumers. Write-without-response honours CoreBluetooth's flow control.
- **`StdioServerTransport`** replaces the SDK's stdio transport, which polls stdin every 10 ms. A dedicated thread waits in a blocking `read`, so an idle server costs no CPU and requests see no polling delay (median ping 0.05 ms instead of 13.7 ms). It is not kqueue-based because on macOS kqueue never reports end of file for named FIFOs. It never changes descriptor flags, which matters because stdin and stdout are shared with the launching process. Writes go through a dedicated serial queue, and a vanished client becomes an `EPIPE` error instead of a fatal `SIGPIPE`.
- **Errors** are typed (`throws(BLEError)`) through the core and backend, and normalised once at each boundary.

Swift features in use: Swift 6 language mode with complete concurrency checking, typed throws, `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `NonisolatedNonsendingByDefault`, custom actor executors, `Mutex` and `Atomic` from `Synchronization`, `UInt128` (UUIDs are a single 128-bit value), `InlineArray`, and phantom-typed identifiers (`ScanID` and `SubscriptionID` cannot be mixed up). Tests use Swift Testing with parameterised cases.

### Adding device-specific tools

`BLEMCPServer(session:additionalTools:)` accepts extra `ToolDefinition`s that share the session. A device library can therefore offer high-level tools, such as `bb500_read_measurement`, on top of the connections and subscriptions the agent created, using the same typed argument system. Module names carry a `BLEMCP` prefix so this package links cleanly next to device packages that have their own `BLECoreBluetooth` or `BLETestSupport` modules.

## Development

```bash
swift build
swift test                       # 65 tests, no Bluetooth hardware needed
swift test --sanitize=thread
npx @modelcontextprotocol/inspector .build/debug/ble-mcp
```

Requires macOS 26 and Swift 6.2 or later.

## Limitations

- macOS only. The core and the MCP layer are platform-neutral, but no Linux (BlueZ) backend exists yet.
- CoreBluetooth reports read responses and notifications through the same callback. A notification that arrives while a read of the same characteristic is pending is taken as the read result.
- No pairing control, L2CAP channels, peripheral (advertiser) role, protocol specs or plugin loading yet.
- stdio transport only.
