import Foundation
import Testing

/// Runs the real `ble-mcp` executable, for behaviour that only exists in the composition root.
@Suite("ble-mcp process", .timeLimit(.minutes(1)))
struct ProcessTests {
    /// SwiftPM puts executables next to the test bundles.
    static let executable: URL? = {
        let url = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ble-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    @Test(
        "SIGINT and SIGTERM shut the server down and exit cleanly, with or without the relaunch",
        arguments: [SIGTERM, SIGINT], [false, true])
    func stopsOnSignal(_ signalNumber: Int32, relaunch: Bool) throws {
        let executable = try #require(Self.executable, "build ble-mcp first")
        let captures = FileManager.default.temporaryDirectory.appendingPathComponent("ble-mcp-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: captures) }

        let process = Process()
        process.executableURL = executable
        process.environment = [
            "BLE_MCP_OWN_PERMISSION": relaunch ? "1" : "0",
            "BLE_MCP_CAPTURE": captures.path,
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        // The answer to `initialize` shows the server is serving, so its signal handlers are in place.
        let request =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"0"}}}"#
        input.fileHandleForWriting.write(Data((request + "\n").utf8))
        var answer = Data()
        while !answer.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            answer.append(chunk)
        }
        #expect(String(decoding: answer, as: UTF8.self).contains(#""serverInfo""#))

        kill(process.processIdentifier, signalNumber)
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)

        // The capture was flushed before the exit.
        let files = try FileManager.default.contentsOfDirectory(atPath: captures.path)
        let file = try #require(files.first)
        let contents = try String(contentsOf: captures.appendingPathComponent(file), encoding: .utf8)
        #expect(contents.contains("capture started"))
    }
}

/// Replay mode and `ble-mcp diff`, end to end through the executable. Neither touches Bluetooth.
@Suite("ble-mcp replay and diff", .timeLimit(.minutes(1)))
struct ReplayProcessTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("BLEMCPReplayTests/Fixtures/bb500-sweep-start.jsonl")

    @Test("BLE_MCP_REPLAY serves a capture over stdio: the BB-500 answers its auth frame")
    func replayMode() throws {
        let executable = try #require(ProcessTests.executable, "build ble-mcp first")
        let process = Process()
        process.executableURL = executable
        process.environment = [
            "BLE_MCP_REPLAY": Self.fixture.path, "BLE_MCP_REPLAY_SPEED": "0",
            "BLE_MCP_ALLOW_WRITES": "1", "BLE_MCP_WRITE_VALUE_ALLOWLIST": "ff01:abcd03fd0278",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }

        var buffer = Data()
        func send(_ line: String) -> [String: Any]? {
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
            while !buffer.contains(UInt8(ascii: "\n")) {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { return nil }
                buffer.append(chunk)
            }
            let newline = buffer.firstIndex(of: UInt8(ascii: "\n"))!
            let message = buffer[..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            return try? JSONSerialization.jsonObject(with: message) as? [String: Any]
        }
        func call(_ id: Int, _ tool: String, _ arguments: String) -> [String: Any]? {
            let response = send(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
            return (response?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        }

        #expect(
            send(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"0"}}}"#
            ) != nil)
        input.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8 + [UInt8(ascii: "\n")]))

        let status = try #require(call(2, "ble_status", "{}"))
        let backend = try #require(status["backend"] as? [String: Any])
        #expect(backend["kind"] as? String == "replay")
        #expect(backend["source"] as? String == Self.fixture.path)
        #expect(backend["recorded_requests"] as? Int == 14)

        let peripheral = "9D290B5A-71BE-5F31-2DB0-81271E936393"
        _ = try #require(call(3, "ble_connect", #"{"peripheral_id":"\#(peripheral)"}"#))
        let exchange = try #require(
            call(
                4, "ble_transact",
                #"{"peripheral_id":"\#(peripheral)","characteristic_uuid":"ff01","value":"abcd03fd0278","reply_uuid":"ff02"}"#))
        let reply = try #require(exchange["reply"] as? [String: Any])
        #expect((reply["value"] as? [String: Any])?["hex"] as? String == "abcd04ff00027b")
    }

    @Test("diff exits 0 for matching captures, 1 for different ones and 2 for unreadable input")
    func diffExitCodes() throws {
        let executable = try #require(ProcessTests.executable, "build ble-mcp first")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ble-mcp-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let changed = directory.appendingPathComponent("changed.jsonl")
        let original = try String(contentsOf: Self.fixture, encoding: .utf8)
        try original.replacingOccurrences(of: "abcd04ff00027b", with: "abcd04ff00027c").write(
            to: changed, atomically: true, encoding: .utf8)

        func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["diff"] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }

        #expect(try run([Self.fixture.path, Self.fixture.path]).status == 0)
        let different = try run([Self.fixture.path, changed.path, "--limit", "1"])
        #expect(different.status == 1)
        #expect(different.output.contains("- line 4: rx   ff02 abcd04ff00027b"))
        // The fixture has no reads, so comparing only reads finds nothing to differ.
        #expect(try run([Self.fixture.path, changed.path, "--kinds", "read"]).status == 0)
        #expect(try run([Self.fixture.path, directory.appendingPathComponent("missing.jsonl").path]).status == 2)
        #expect(try run([Self.fixture.path]).status == 2)
        #expect(try run([Self.fixture.path, Self.fixture.path, "--kinds", "rssi"]).status == 2)
    }
}

/// Locates this test bundle; Swift Testing does not list it in `Bundle.allBundles`.
private final class BundleAnchor {}
