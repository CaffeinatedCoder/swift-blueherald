# swift-ble-mcp

A Bluetooth Low Energy [Model Context Protocol](https://modelcontextprotocol.io) server for macOS, written in Swift 6. It lets an AI agent scan for BLE devices, connect, explore their GATT tables, read and write characteristics, stream notifications and record everything as a JSONL capture, all through 19 typed MCP tools. A capture can be played back in place of the radio, so agents, device libraries and tests can work with a recorded device when the real one is out of reach.

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

A characteristic allowlist lets any value through. For a device whose commands share one characteristic, list the exact frames instead: `BLE_MCP_WRITE_VALUE_ALLOWLIST=ff01:abcd03fd0278` (or a file of them via `BLE_MCP_WRITE_VALUE_ALLOWLIST_FILE`) restricts `ff01` to those frames, and `BLE_MCP_WRITE_DENYLIST` names characteristics that are never written, whatever else is configured.

For other clients, launch `ble-mcp` as a stdio server and pass the variables below as its environment.

### Bluetooth permission

The first BLE operation triggers the macOS prompt *"ble-mcp would like to use Bluetooth"*. Accept it. Until you do, `ble_status` reports `adapter_state: awaiting_permission` and other tools fail with `bluetooth_unavailable` and a hint. The first start after ble-mcp is rebuilt or updated can also take several seconds while macOS checks the new binary; `ble_status` waits for that rather than reporting `unknown`.

macOS normally attributes a command-line tool's privacy permissions to the app that launched it. If that app (Claude, an IDE) has no Bluetooth usage description, macOS kills the tool outright. `ble-mcp` therefore relaunches itself once at startup as its own "responsible process", so the permission belongs to `ble-mcp` regardless of the launcher. Set `BLE_MCP_OWN_PERMISSION=0` to turn this off.

Development builds are ad-hoc signed, so each rebuild is a new identity to macOS and may ask again.

## Tools

| Tool | Does |
|---|---|
| `ble_status` | Adapter state, when the server started, write policy, limits, capture file, every open scan, connection and subscription, links that dropped since, and a replay's progress |
| `ble_scan` | Blocking scan with filters (`name`, `service_uuids`, `min_rssi`, `manufacturer_id`, `connectable_only`); `stop_after` returns as soon as enough matches are found |
| `ble_scan_start` / `ble_scan_results` / `ble_scan_stop` | Background scans that run while the agent does other work |
| `ble_connect` / `ble_disconnect` / `ble_connections` | Connections; connecting discovers the full attribute table by default. Disconnecting a peripheral that is not connected succeeds with `was_connected: false` |
| `ble_discover` | Services, characteristics (with properties) and descriptors, with names for well-known UUIDs and each characteristic's own 0x2901 user description |
| `ble_read` / `ble_read_descriptor` | Values as hex, plus UTF-8 text when printable |
| `ble_write` / `ble_write_descriptor` | Only listed when writes are enabled; `value` in hex, base64 or utf8 |
| `ble_transact` | Only listed when writes are enabled. Writes a frame and returns the device's reply, the first notification on `reply_uuid` after the write (optionally starting with `reply_prefix`), with its latency, in one call. The reply characteristic is subscribed to before the write, so a fast answer is never missed |
| `ble_subscribe` / `ble_unsubscribe` | Notifications and indications into a bounded per-subscription buffer |
| `ble_notifications` | Drains buffered values in arrival order across subscriptions; `wait_ms` blocks until data arrives instead of polling, and `note` says when there was no open subscription to wait on |
| `ble_rssi` | Signal strength of a connected peripheral |
| `ble_capture_mark` | Only listed while capturing; labels the next steps of an experiment in the capture |

Every argument is declared once, as a `ToolArgument`. The same declaration produces the JSON schema and does the parsing, so the two cannot drift. Parsing is lenient about encoding: `5000`, `5000.0` and `"5000"` are the same integer, and UUIDs may be `2a19`, `0x2A19` or the full form. Meaning is checked strictly: unknown arguments, fractional or out-of-range numbers and malformed UUIDs are rejected with a message naming the argument.

Failures come back as tool results with `isError: true` and a body like:

```json
{"error":{"code":"ambiguous_characteristic","message":"Characteristic FFE1 exists in several services: FFE0, FFF0.","hint":"Pass service_uuid to choose one."}}
```

A link the peripheral or the adapter drops is remembered until the peripheral reconnects: the next call for it fails with `disconnected`, the reason and the time, and `ble_status` lists it. Disconnects and adapter changes are also pushed as MCP log notifications, but many clients do not show those to the agent.

CoreBluetooth has no pairing API; pairing starts when the agent touches an attribute that needs encryption. Those failures come back as `pairing_required` (macOS is showing a pairing dialog a person has to confirm) or `pairing_failed` (the device lost this Mac's keys, or nobody confirmed), each with a hint.

### Device data is untrusted

Device names, 0x2901 descriptions and the text of values come from the devices themselves and end up in the agent's context, so a device can try to steer the agent. Names and descriptions are cleaned where they enter the server (control and invisible formatting characters removed, whitespace collapsed, at most 64 characters), value text is cut at 128 characters (`hex` always has the whole value), and the server instructions tell the agent to treat all of it as data, never as instructions. Keep writes off, or narrowed to exact frames, when working with devices you do not control.

## Capturing a session

Set `BLE_MCP_CAPTURE` to a directory (each run gets its own `ble-mcp-<date>-<time>.jsonl`) or to a file (appended to). Every write, notification, read and link change is then recorded as one JSON line, in the format swift-dragoman's `CaptureLog` loads as a test fixture:

```json
{"t": 0.000, "dir": "info", "note": "capture started", "server": "ble-mcp 0.1.0", "started_at": "2026-10-28T05:20:00.000Z"}
{"t": 2.865, "dir": "info", "uuid": "ff02", "note": "notify enabled on ff02"}
{"t": 2.865, "dir": "info", "note": "select AC V", "expect_mode": 1, "select": "G"}
{"t": 2.866, "dir": "tx", "uuid": "ff01", "hex": "abcd03fd0278", "mode": "with_response"}
{"t": 3.090, "dir": "rx", "uuid": "ff02", "hex": "abcd04ff00027b"}
```

`t` counts seconds from the start of the run, and a notification carries the time it arrived. `tx` rows are written before the value goes out, so a request always precedes its reply; a write that then fails gets an `info` row with the error. Reads, descriptor traffic, connects and disconnects are `info` rows too, so `rx` holds only what the device sent unprompted. The agent labels steps with `ble_capture_mark` (`note` plus string, number or boolean fields), which is what `CaptureLog.segments(markedBy:)` splits a fixture on. Each row is a single append, so a crash loses nothing that was recorded.

Two `info` rows exist for replays. When the session connects, it records what scans saw of that device (`"note": "advertisement"`: name, RSSI, advertised services, manufacturer and service data). Only the device under test is recorded, not its neighbours. After discovery, the attribute table is recorded with its properties, descriptors and 0x2901 names (`"note": "gatt"`, with a nested `services` array). `CaptureLog` skips nested values, so fixtures load as before.

## Replaying a capture

Set `BLE_MCP_REPLAY` to a capture and the server plays it instead of using Bluetooth. No radio is involved, no permission is asked, and it also runs where CoreBluetooth doesn't exist. Recorded devices advertise, accept connections and return their recorded attribute tables. The rest follows the recorded timeline:

- **Writes.** A write is matched to the next unused recorded write of the same bytes to the same characteristic. The notifications that followed it are sent again with their recorded delays, divided by `BLE_MCP_REPLAY_SPEED` (`0` sends them at once). A frame repeated more often than recorded gets the replies of its latest copy. A frame the capture never sent is accepted with no reply and listed under `backend.divergences` in `ble_status`. With `BLE_MCP_REPLAY_STRICT=1` it fails instead, naming the write the capture makes next.
- **Subscriptions** are matched the same way, so a device that streams once subscribed streams again.
- **Reads** return the latest value recorded up to that point in the timeline. A read after a replayed write therefore sees what the device answered then.
- **Link losses** that were recorded happen again.

Writes still need `BLE_MCP_ALLOW_WRITES` and pass the allowlists, so an agent configured for the real device behaves the same against the replay.

Older captures, and swift-dragoman's fixtures, have no `advertisement` or `gatt` rows. For those the attribute table is inferred: written characteristics become writable, notifying ones notify and read ones are readable, all in one service `52455050-4C41-5900-0000-000000000000` ("REPLAY" in ASCII). The peripheral id comes from the `connected` row or a `device <id>` note.

```bash
BLE_MCP_REPLAY=bb500-sweep.jsonl BLE_MCP_REPLAY_SPEED=0 BLE_MCP_ALLOW_WRITES=1 ble-mcp
```

`BLEMCPReplay` is also a library product: `ReplayCentral` slots into a `BLESession` like any backend, for tests of code built on the session.

### Comparing captures

```bash
ble-mcp diff before.jsonl after.jsonl [--kinds tx,rx,read] [--limit 20]
```

Compares writes, notifications and characteristic reads by characteristic and bytes, in order. Timing, markers and other `info` rows are ignored. It prints the counts on each side and each difference with its line number, and exits 0 when the captures match, 1 when they differ and 2 on unreadable input, so it can gate CI. The regression loop: record a session, replay it with `BLE_MCP_CAPTURE` on while running the same steps, and diff the two captures.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `BLE_MCP_ALLOW_WRITES` | off | `1`/`true`/`yes` enables the write tools |
| `BLE_MCP_WRITE_ALLOWLIST` | all | Comma-separated characteristic UUIDs that may be written with any value; descriptor writes are checked against their characteristic |
| `BLE_MCP_WRITE_VALUE_ALLOWLIST` | none | Comma-separated `characteristic:hex` frames, e.g. `ff01:abcd03fd0278`; a listed characteristic accepts only its frames |
| `BLE_MCP_WRITE_VALUE_ALLOWLIST_FILE` | none | A file with one `characteristic:hex` frame per line (`#` starts a comment), merged with the above |
| `BLE_MCP_WRITE_DENYLIST` | none | Comma-separated characteristic UUIDs that are never written |
| `BLE_MCP_CAPTURE` | off | Directory or file for the [JSONL capture](#capturing-a-session) |
| `BLE_MCP_MAX_CONNECTIONS` | 4 | Simultaneous connections (1–32) |
| `BLE_MCP_MAX_SUBSCRIPTIONS` | 32 | Active subscriptions (1–512) |
| `BLE_MCP_MAX_SCANS` | 4 | Concurrent background scans (1–16) |
| `BLE_MCP_NOTIFICATION_BUFFER` | 1024 | Values kept per subscription; the oldest are dropped first and counted |
| `BLE_MCP_CONNECT_TIMEOUT_MS` | 15000 | Connection timeout |
| `BLE_MCP_OPERATION_TIMEOUT_MS` | 10000 | Read, write, subscribe and RSSI timeout |
| `BLE_MCP_LOG_LEVEL` | warning | stderr log level; `info` logs every tool call with its duration |
| `BLE_MCP_OWN_PERMISSION` | 1 | See [Bluetooth permission](#bluetooth-permission) |
| `BLE_MCP_REPLAY` | off | A JSONL capture to [play instead of using Bluetooth](#replaying-a-capture) |
| `BLE_MCP_REPLAY_SPEED` | 1 | Replay pace: `1` as recorded, `2` twice as fast, `0` without delays (0–1000) |
| `BLE_MCP_REPLAY_STRICT` | off | Fail writes the capture does not make next, instead of accepting them without a reply |

An invalid value stops the server at startup with a message naming the variable. It is never silently replaced by a default. Run `ble-mcp --help` for the same list.

## Architecture

```
ble-mcp              composition root: environment, logging, signals, stdio
BLEMCPServer         MCP adapter: ToolArgument schemas, ToolDefinition catalogue, wire models
BLEMCPCoreBluetooth  BLECentral on CoreBluetooth
BLEMCPReplay         BLECentral that plays a capture; capture loading and diffing
BLEMCPCore           domain model, BLECentral protocol, BLESession actor (no platform I/O)
```

- **`BLESession`** (actor) owns all state: scans, connections, subscriptions and their ring buffers. Everything leaves it as immutable snapshot values. Because actors are re-entrant, every method that suspends re-validates its preconditions afterwards and claims capacity *before* awaiting, so concurrent calls cannot overshoot a limit.
- **`BLECentral`** is the backend seam: CoreBluetooth in production, `ReplayCentral` for recorded devices, a scripted `FakeCentral` in tests, BlueZ on Linux some day. A simulated backend can report its state through `report()`, which `ble_status` shows as `backend`. Its contract is that every operation honours cancellation. The session enforces all timeouts in one place by racing the operation against a deadline in a task group.
- **`CoreBluetoothCentral`** is an actor whose executor *is* CoreBluetooth's dispatch queue. (Its request helper, like the session's waits, passes its isolation to `withTaskCancellationHandler` explicitly: with Swift 6.4's `nonisolated(nonsending)` overload, release builds lost the hop back to that queue after a continuation resumed. See [swiftlang/swift#92915](https://github.com/swiftlang/swift/issues/92915).) Delegate callbacks enter it synchronously through `assumeIsolated`, with no locks and no hops. `CBPeripheral` calls run on the queue CoreBluetooth expects, and the non-`Sendable` CoreBluetooth objects never leave the actor. Pending requests are continuations in FIFO tables keyed by object identity, and each one is removed before it is resumed, so a callback, a timeout and a disconnect racing for the same request resume it exactly once. CoreBluetooth cannot withdraw a request it has sent, so a timed-out read, write, notification change or RSSI read keeps a placeholder in its queue: its late answer is dropped there instead of answering the next request. A single radio scan is shared by any number of scan consumers. Write-without-response honours CoreBluetooth's flow control.
- **`StdioServerTransport`** replaces the SDK's stdio transport, which polls stdin every 10 ms. A dedicated thread waits in a blocking `read`, so an idle server costs no CPU and requests see no polling delay (median ping 0.05 ms instead of 13.7 ms). It is not kqueue-based because on macOS kqueue never reports end of file for named FIFOs. It never changes descriptor flags, which matters because stdin and stdout are shared with the launching process. Writes go through a dedicated serial queue, and a vanished client becomes an `EPIPE` error instead of a fatal `SIGPIPE`. At end of input it waits up to 30 seconds for the requests it already read to be answered before the session ends, so a client that closes stdin right after its last request still gets the result.
- **Errors** are typed (`throws(BLEError)`) through the core and backend, and normalised once at each boundary.
- **Captures** are recorded by the session, which knows what the agent asked for, through a `CaptureSink`. `JSONLCaptureFile` formats and appends rows on its own serial queue, off the session's executor.

Swift features in use: Swift 6 language mode with complete concurrency checking, typed throws, `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `NonisolatedNonsendingByDefault`, custom actor executors, `Mutex` and `Atomic` from `Synchronization`, `UInt128` (UUIDs are a single 128-bit value), `InlineArray`, and phantom-typed identifiers (`ScanID` and `SubscriptionID` cannot be mixed up). Tests use Swift Testing with parameterised cases.

### Adding device-specific tools

`BLEMCPServer(session:additionalTools:)` accepts extra `ToolDefinition`s that share the session. A device library can therefore offer high-level tools, such as `bb500_read_measurement`, on top of the connections and subscriptions the agent created, using the same typed argument system. Module names carry a `BLEMCP` prefix so this package links cleanly next to device packages such as swift-dragoman (`DragomanCore`, `DragomanCoreBluetooth`, `DragomanTesting`).

## Development

```bash
swift build
swift test                       # no Bluetooth hardware needed (FakeCentral and ReplayCentral)
swift test -c release            # the same, optimised
swift test --sanitize=thread
npx @modelcontextprotocol/inspector .build/debug/ble-mcp
```

The tests run against `FakeCentral`, so they cannot cover `CoreBluetoothCentral`. Check changes there with a **release** build against a real device: the optimiser has changed how its actor hops behave before. `Scripts/hardware-smoke.swift` does that in about ten seconds, read-only, and exits non-zero on any failure:

```bash
swift build -c release
swift Scripts/hardware-smoke.swift --name iPhone --read 2A29,2A19 --subscribe 2A2B
```

It scans, connects, reads, subscribes, disconnects, stops the server with SIGTERM while connected and checks the capture it wrote. `--transact ff01:abcd03fd0278:ff02:abcd04ff` adds one request/reply exchange; only then does the script write, and the server it starts allows exactly that frame.

The script passes its environment on to the server, so it can also run against the capture it just wrote, with no device. Then `ble-mcp diff` should report the two captures identical:

```bash
BLE_MCP_REPLAY=/path/to/its/capture.jsonl swift Scripts/hardware-smoke.swift --name iPhone --read 2A29,2A19 --subscribe 2A2B
```

Requires macOS 26 and Swift 6.2 or later.

## Limitations

- Bluetooth on macOS only. The core, the MCP layer and replays are platform-neutral, but no Linux (BlueZ) backend exists yet.
- Replays answer with what was recorded, not with a model of the device. A recorded write failure is not replayed, and captures made only by scanning (with no connection) don't record advertisements.
- CoreBluetooth reports read responses and notifications through the same callback. A notification that arrives while a read of the same characteristic is pending is taken as the read result.
- No pairing control, L2CAP channels, peripheral (advertiser) role, protocol specs or plugin loading yet.
- stdio transport only.
