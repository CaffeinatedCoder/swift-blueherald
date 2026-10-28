#!/usr/bin/env swift
// Checks a ble-mcp build against a real peripheral: the part the unit tests cannot reach,
// because they run against FakeCentral. Use a release build; the optimiser has changed how
// CoreBluetoothCentral's actor hops behave before.
//
//   swift build -c release
//   swift Scripts/hardware-smoke.swift --name iPhone --read 2A29,2A19 --subscribe 2A2B
//
// Options:
//   --name TEXT          find the peripheral by advertised name (substring)
//   --peripheral ID      or connect to a peripheral id this Mac already knows
//   --read UUIDS         comma-separated characteristics to read (default: 2A29)
//   --subscribe UUID     a notify/indicate characteristic to subscribe to (optional)
//   --transact C:HEX:R[:PREFIX]
//                        write the frame HEX to characteristic C with ble_transact and expect a
//                        reply on R (starting with PREFIX); the only write the script ever makes
//   --binary PATH        the server to test (default: .build/release/ble-mcp)
//
// Without --transact it never writes to the device; with it, the server is started with exactly
// that one frame on its write allowlist. For a Voltcraft BB-500, the harmless known-device auth:
//
//   swift Scripts/hardware-smoke.swift --name BB --read 2A29 --transact ff01:abcd03fd0278:ff02:abcd04ff
//
// The binary needs Bluetooth permission. Exit status 0 means every check passed.

import Foundation

// MARK: - Options

struct Options {
    var binary = ".build/release/ble-mcp"
    var name: String?
    var peripheral: String?
    var reads = ["2A29"]
    var subscribe: String?
    var transact: (characteristic: String, frame: String, reply: String, prefix: String?)?

    init(_ arguments: [String]) {
        var remaining = arguments.dropFirst()[...]
        while let flag = remaining.popFirst() {
            guard let value = remaining.popFirst() else { Self.usage("\(flag) needs a value") }
            switch flag {
            case "--binary": binary = value
            case "--name": name = value
            case "--peripheral": peripheral = value
            case "--read": reads = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case "--subscribe": subscribe = value
            case "--transact":
                let parts = value.split(separator: ":").map(String.init)
                guard (3...4).contains(parts.count) else { Self.usage("--transact takes CHAR:HEX:REPLY[:PREFIX]") }
                transact = (parts[0], parts[1], parts[2], parts.count == 4 ? parts[3] : nil)
            default: Self.usage("unknown option \(flag)")
            }
        }
        if name == nil, peripheral == nil { Self.usage("pass --name or --peripheral") }
    }

    static func usage(_ problem: String) -> Never {
        FileHandle.standardError.write(Data("hardware-smoke: \(problem). See the header of Scripts/hardware-smoke.swift.\n".utf8))
        exit(EX_USAGE)
    }
}

// MARK: - A server over stdio

/// Runs ble-mcp as a child process and matches JSON-RPC responses to requests by id.
final class Server: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var responses: [Int: [String: Any]] = [:]
    private var lastID = 0

    init(binary: String, environment: [String: String], log: URL) throws {
        process.executableURL = URL(fileURLWithPath: binary)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: log)
        try process.run()
        Thread.detachNewThread { [self] in readResponses() }
    }

    private func readResponses() {
        var buffer = Data()
        while case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let id = message["id"] as? Int
                else { continue }
                condition.lock()
                responses[id] = message
                condition.broadcast()
                condition.unlock()
            }
        }
    }

    func send(_ message: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: message)
        input.fileHandleForWriting.write(data + Data("\n".utf8))
    }

    /// Sends a request and waits for its response.
    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 45) -> [String: Any]? {
        condition.lock()
        lastID += 1
        let id = lastID
        condition.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, condition.wait(until: deadline) {}
        return responses.removeValue(forKey: id)
    }

    /// Calls a tool; returns its structured result and whether it was an error result.
    func call(_ tool: String, _ arguments: [String: Any] = [:]) -> (json: [String: Any], isError: Bool) {
        guard let response = request("tools/call", ["name": tool, "arguments": arguments]),
            let result = response["result"] as? [String: Any]
        else { return (["error": ["message": "no response to \(tool)"]], true) }
        return (result["structuredContent"] as? [String: Any] ?? [:], result["isError"] as? Bool ?? false)
    }

    /// Sends SIGTERM and returns the exit status (128 + signal when a signal ended it).
    func terminate() -> Int32 {
        process.terminate()
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    }
}

// MARK: - Checks

final class Report {
    private(set) var failures = 0
    private var passes = 0

    /// Records one check; `detail` explains a failure or adds context to a pass.
    func check(_ title: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        let text = detail()
        print("\(passed ? "✔" : "✘") \(title)\(text.isEmpty ? "" : " — \(text)")")
        if passed { passes += 1 } else { failures += 1 }
    }

    var summary: String { "\(passes) passed, \(failures) failed" }
}

func describe(_ json: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return "\(json)" }
    return String(decoding: data.prefix(300), as: UTF8.self)
}

let options = Options(CommandLine.arguments)
guard FileManager.default.isExecutableFile(atPath: options.binary) else {
    Options.usage("no executable at \(options.binary); run swift build -c release first")
}

let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ble-mcp-smoke-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
let log = workspace.appendingPathComponent("server.log")
let report = Report()
print("ble-mcp hardware smoke test: \(options.binary)\nlogs and capture: \(workspace.path)\n")

var environment = ["BLE_MCP_LOG_LEVEL": "info", "BLE_MCP_CAPTURE": workspace.path]
if let exchange = options.transact {
    // Writes stay off for everything but this one frame.
    environment["BLE_MCP_ALLOW_WRITES"] = "1"
    environment["BLE_MCP_WRITE_VALUE_ALLOWLIST"] = "\(exchange.characteristic):\(exchange.frame)"
}
let server = try Server(binary: options.binary, environment: environment, log: log)

let initialized = server.request(
    "initialize",
    ["protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "hardware-smoke", "version": "1"]])
report.check("server answers initialize", (initialized?["result"] as? [String: Any])?["serverInfo"] != nil)
server.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

let (status, _) = server.call("ble_status")
report.check("adapter is powered on", status["adapter_state"] as? String == "powered_on", describe(status))
guard status["adapter_state"] as? String == "powered_on" else {
    print("\nStopping: nothing else can work. \(report.summary)")
    exit(1)
}

let started = Date()
let (idle, _) = server.call("ble_notifications", ["wait_ms": 3_000])
report.check(
    "a wait without subscriptions returns at once and says why",
    Date().timeIntervalSince(started) < 2 && (idle["note"] as? String)?.contains("ble_subscribe") == true,
    describe(idle))

var peripheral = options.peripheral
if let name = options.name {
    let (scan, scanError) = server.call("ble_scan", ["name": name, "duration_ms": 8_000, "stop_after": 1])
    let device = (scan["devices"] as? [[String: Any]])?.first
    report.check("scan finds \"\(name)\"", !scanError && device != nil, describe(scan))
    peripheral = peripheral ?? device?["peripheral_id"] as? String
}
guard let peripheral else {
    print("\nStopping: no peripheral to connect to. \(report.summary)")
    _ = server.terminate()
    exit(1)
}

let (unlinked, _) = server.call("ble_disconnect", ["peripheral_id": peripheral])
report.check("disconnecting without a link succeeds", unlinked["was_connected"] as? Bool == false, describe(unlinked))

let (connection, connectError) = server.call("ble_connect", ["peripheral_id": peripheral])
let services = connection["services"] as? [[String: Any]] ?? []
report.check(
    "connect discovers the attribute table", !connectError && !services.isEmpty,
    connectError ? describe(connection) : "\(services.count) services")

for uuid in options.reads {
    let (reading, readError) = server.call("ble_read", ["peripheral_id": peripheral, "characteristic_uuid": uuid])
    let value = reading["value"] as? [String: Any]
    report.check(
        "read \(uuid)", !readError && value?["hex"] is String,
        readError ? describe(reading) : "hex \(value?["hex"] ?? "?")" + ((value?["utf8"] as? String).map { ", text \"\($0)\"" } ?? ""))
}

if let exchange = options.transact {
    var arguments: [String: Any] = [
        "peripheral_id": peripheral, "characteristic_uuid": exchange.characteristic, "value": exchange.frame,
        "reply_uuid": exchange.reply, "timeout_ms": 3_000,
    ]
    arguments["reply_prefix"] = exchange.prefix
    let (result, transactError) = server.call("ble_transact", arguments)
    let reply = result["reply"] as? [String: Any]
    let hex = (reply?["value"] as? [String: Any])?["hex"] as? String
    report.check(
        "transact \(exchange.frame) on \(exchange.characteristic) gets its reply on \(exchange.reply)",
        !transactError && hex.map { $0.hasPrefix(exchange.prefix?.lowercased() ?? "") } == true,
        hex.map { "reply \($0) after \(reply?["latency_ms"] ?? "?") ms" } ?? describe(result))
}

let (rssi, rssiError) = server.call("ble_rssi", ["peripheral_id": peripheral])
report.check("RSSI", !rssiError && rssi["rssi"] is Int, describe(rssi))

if let uuid = options.subscribe {
    let (subscription, subscribeError) = server.call("ble_subscribe", ["peripheral_id": peripheral, "characteristic_uuid": uuid])
    report.check("subscribe to \(uuid)", !subscribeError && subscription["state"] as? String == "active", describe(subscription))
    if let id = subscription["subscription_id"] as? String {
        let (batch, _) = server.call("ble_notifications", ["subscription_id": id, "wait_ms": 2_000])
        let received = (batch["notifications"] as? [Any])?.count ?? 0
        report.check(
            "notifications arrive, or the wait says it ran out",
            received > 0 || (batch["note"] as? String)?.hasPrefix("Waited") == true,
            received > 0 ? "\(received) received" : describe(batch))
        let (closed, _) = server.call("ble_unsubscribe", ["subscription_id": id])
        report.check("unsubscribe", closed["state"] as? String == "closed", describe(closed))
    }
}

let (disconnected, _) = server.call("ble_disconnect", ["peripheral_id": peripheral])
report.check("disconnect", disconnected["was_connected"] as? Bool == true, describe(disconnected))

// Stop the way an MCP client does, with a live link, and check the shutdown ran to the end.
let (relinked, relinkError) = server.call("ble_connect", ["peripheral_id": peripheral, "discover": false])
report.check("reconnect before stopping", !relinkError, relinkError ? describe(relinked) : "")
let exitStatus = server.terminate()
report.check("SIGTERM exits cleanly", exitStatus == 0, "exit status \(exitStatus)")

let captureFile = try FileManager.default.contentsOfDirectory(atPath: workspace.path).first { $0.hasSuffix(".jsonl") }
let rows = try captureFile.map { try String(contentsOf: workspace.appendingPathComponent($0), encoding: .utf8) }?
    .split(separator: "\n")
    .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
report.check("capture starts with its info row", rows.first?["note"] as? String == "capture started")
report.check(
    "capture records the reads", rows.contains { $0["note"] as? String == "read" },
    "\(rows.count) rows")
if let exchange = options.transact {
    let request = rows.firstIndex { $0["dir"] as? String == "tx" && $0["hex"] as? String == exchange.frame.lowercased() }
    let reply = request.flatMap { index in rows[index...].firstIndex { $0["dir"] as? String == "rx" } }
    report.check("capture holds the request before its reply", request != nil && reply != nil)
}
report.check(
    "capture ends with the shutdown's disconnect",
    rows.last?["note"] as? String == "disconnected" && rows.last?["reason"] as? String == "server shutting down",
    rows.last.map(describe) ?? "no rows")

print("\n\(report.summary)")
if report.failures > 0 { print("server log: \(log.path)") }
exit(report.failures == 0 ? 0 : 1)
