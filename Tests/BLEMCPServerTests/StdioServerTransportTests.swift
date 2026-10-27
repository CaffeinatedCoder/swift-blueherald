import BLEMCPCore
@testable import BLEMCPServer
import BLEMCPTestSupport
import Foundation
import MCP
import Testing

@Suite("Line framing")
struct LineFramerTests {
    func strings(_ output: LineFramer.Output) -> [String] {
        output.messages.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("several messages in one chunk, CRLF endings and blank lines")
    func oneChunk() {
        var framer = LineFramer()
        #expect(strings(framer.append(Array("{\"a\":1}\n\n{\"b\":2}\r\n{\"c\"".utf8))) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(strings(framer.append(Array(":3}\n".utf8))) == ["{\"c\":3}"])
    }

    @Test("a message fed one byte at a time")
    func byteByByte() {
        var framer = LineFramer()
        var received: [String] = []
        for byte in "{\"id\":1}\r\n{\"id\":2}\n".utf8 {
            received += strings(framer.append(CollectionOfOne(byte)))
        }
        #expect(received == ["{\"id\":1}", "{\"id\":2}"])
    }

    @Test("an oversized message is discarded up to its newline; the next one survives")
    func oversized() {
        var framer = LineFramer(maximumMessageLength: 8)
        let first = framer.append(Array("0123456789".utf8))
        #expect(first.discardedOversizedMessage)
        #expect(first.messages.isEmpty)
        #expect(strings(framer.append(Array("still too long\nok\n".utf8))) == ["ok"])
    }
}

@Suite("Stdio transport")
struct StdioServerTransportTests {
    let input = Pipe()
    let output = Pipe()

    func makeTransport() -> StdioServerTransport {
        StdioServerTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor)
    }

    func feed(_ text: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    @Test("messages arrive in order however the writes are split, and EOF ends the stream")
    func receives() async throws {
        let transport = makeTransport()
        await transport.connect()
        try feed("{\"id\":1}\n{\"id\"")
        try await Task.sleep(for: .milliseconds(20))
        try feed(":2}\n")
        try input.fileHandleForWriting.close()

        var received: [String] = []
        for try await message in transport.receive() {
            received.append(String(decoding: message, as: UTF8.self))
        }
        #expect(received == ["{\"id\":1}", "{\"id\":2}"])
    }

    /// macOS kqueue and poll never report EOF on a named FIFO, so this guards the reader design.
    @Test("EOF on a named FIFO ends the stream", .timeLimit(.minutes(1)))
    func fifoEOF() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "ble-mcp-\(UUID().uuidString).fifo").path
        #expect(mkfifo(path, 0o600) == 0)
        defer { unlink(path) }
        // Open the read end without blocking for a writer, then make it blocking again like a shell redirect.
        let reader = open(path, O_RDONLY | O_NONBLOCK)
        #expect(fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) & ~O_NONBLOCK) == 0)
        let writer = open(path, O_WRONLY)
        defer { close(reader) }

        let transport = StdioServerTransport(input: reader, output: output.fileHandleForWriting.fileDescriptor)
        await transport.connect()
        _ = Data("{\"id\":1}\n".utf8).withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
        close(writer)

        var received: [String] = []
        for try await message in transport.receive() {
            received.append(String(decoding: message, as: UTF8.self))
        }
        #expect(received == ["{\"id\":1}"])
    }

    @Test("a regular file as stdin is read to the end", .timeLimit(.minutes(1)))
    func regularFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ble-mcp-\(UUID().uuidString).jsonl")
        try Data("{\"id\":1}\n{\"id\":2}\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)

        let transport = StdioServerTransport(input: handle.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
        await transport.connect()
        var count = 0
        for try await _ in transport.receive() {
            count += 1
        }
        #expect(count == 2)
        try handle.close()
    }

    @Test("sent messages are newline-terminated and keep their order")
    func sends() async throws {
        let transport = makeTransport()
        await transport.connect()
        for id in 1...50 {
            try await transport.send(Data("{\"id\":\(id)}".utf8))
        }
        await transport.disconnect()
        try output.fileHandleForWriting.close()

        let written = try #require(try output.fileHandleForReading.readToEnd())
        let expected = (1...50).map { "{\"id\":\($0)}\n" }.joined()
        #expect(String(decoding: written, as: UTF8.self) == expected)
    }

    @Test("a client that went away surfaces as an error, not SIGPIPE")
    func brokenPipe() async throws {
        let transport = makeTransport()
        await transport.connect()
        try output.fileHandleForReading.close()
        await #expect(throws: MCPError.self) {
            try await transport.send(Data("{}".utf8))
        }
    }

    @Test("sending after disconnect is refused")
    func sendAfterDisconnect() async throws {
        let transport = makeTransport()
        await transport.connect()
        await transport.disconnect()
        await #expect(throws: MCPError.self) {
            try await transport.send(Data("{}".utf8))
        }
    }

    @Test("an MCP server answers over it")
    func serverRoundTrip() async throws {
        let session = BLESession(central: FakeCentral(devices: [Fixtures.meter()]))
        let server = await BLEMCPServer(session: session).makeServer()
        try await server.start(transport: makeTransport())

        try feed(
            """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ble_status","arguments":{}}}

            """)

        var responses: [Int: [String: Any]] = [:]
        for try await line in output.fileHandleForReading.bytes.lines {
            let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let id = message["id"] as? Int {
                responses[id] = message
            }
            if responses.count == 2 { break }
        }
        let initialize = try #require(responses[1]?["result"] as? [String: Any])
        #expect((initialize["serverInfo"] as? [String: Any])?["name"] as? String == "ble-mcp")
        let status = try #require(responses[2]?["result"] as? [String: Any])
        #expect(status["isError"] as? Bool == false)
        await server.stop()
    }
}
