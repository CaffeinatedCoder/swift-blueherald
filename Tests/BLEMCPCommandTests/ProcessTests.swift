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
        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"tests","version":"0"}}}"#
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

/// Locates this test bundle; Swift Testing does not list it in `Bundle.allBundles`.
private final class BundleAnchor {}
