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

    /// A non-blocking pipe that is read slowly takes a large message in many short writes, and
    /// `EAGAIN` in between: every byte must still arrive once, in order.
    @Test("a large message survives short writes", .timeLimit(.minutes(1)))
    func shortWrites() async throws {
        let descriptor = output.fileHandleForWriting.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0)
        let transport = makeTransport()
        await transport.connect()
        let message = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })

        let reader = output.fileHandleForReading.fileDescriptor
        let expected = message.count + 1
        let received = Task.detached {
            var bytes = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while bytes.count < expected {
                let count = chunk.withUnsafeMutableBytes { read(reader, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                bytes.append(contentsOf: chunk[..<count])
                // Pause now and then, so the pipe fills and the writer meets EAGAIN.
                if bytes.count % (64 * 1024) < count { try await Task.sleep(for: .milliseconds(1)) }
            }
            return bytes
        }
        try await transport.send(message)
        // Whatever was not written by now never will be: end the reader at what arrived.
        try output.fileHandleForWriting.close()
        let bytes = try await received.value
        #expect(bytes.count == message.count + 1)
        #expect(bytes == message + Data([UInt8(ascii: "\n")]))
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

@Suite("End of input", .timeLimit(.minutes(1)))
struct EndOfInputTests {
    let input = Pipe()
    let output = Pipe()

    func responses(after lines: [String], drainTimeout: Duration = .seconds(30)) async throws -> [Int] {
        let session = BLESession(central: FakeCentral(devices: [Fixtures.meter()]))
        let transport = StdioServerTransport(
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor,
            drainTimeout: drainTimeout)
        try input.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        try await BLEMCPServer(session: session).run(on: transport)
        try output.fileHandleForWriting.close()
        let written = try output.fileHandleForReading.readToEnd() ?? Data()
        return try String(decoding: written, as: UTF8.self).split(separator: "\n").compactMap { line in
            try (JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"] as? Int
        }
    }

    static let initialize =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
    static let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

    @Test("requests sent just before stdin closes are still answered")
    func answersBeforeEOF() async throws {
        let ids = try await responses(after: [
            Self.initialize, Self.initialized,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ble_status","arguments":{}}}"#,
        ])
        #expect(Set(ids) == [1, 2, 3])
    }

    func ledger() -> (RequestLedger, AsyncThrowingStream<Data, any Error>) {
        let (stream, sink) = AsyncThrowingStream.makeStream(of: Data.self)
        return (RequestLedger(sink: sink), stream)
    }

    func ends(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> Bool {
        for try await _ in stream {}
        return true
    }

    @Test("end of input waits for responses, batches included, but not for notifications or responses")
    func waitsForRequests() async throws {
        let (ledger, stream) = ledger()
        ledger.received(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        ledger.received(Data(#"[{"jsonrpc":"2.0","id":"a","method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#.utf8))
        ledger.received(Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8))
        #expect(ledger.inputEnded(drainTimeout: .seconds(30)) == 2)
        ledger.sent(Data(#"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#.utf8))
        ledger.sent(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        #expect(ledger.unansweredCount == 1)
        ledger.sent(Data(#"[{"jsonrpc":"2.0","id":"a","result":{}}]"#.utf8))
        #expect(try await ends(stream))
    }

    @Test("a cancelled request is not waited for, since the SDK does not answer it")
    func cancelled() async throws {
        let (ledger, stream) = ledger()
        ledger.received(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ble_scan"}}"#.utf8))
        ledger.received(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#.utf8))
        #expect(ledger.inputEnded(drainTimeout: .seconds(30)) == 0)
        #expect(try await ends(stream))
    }

    @Test("an unanswered request holds end of input only for the drain timeout")
    func drainTimeout() async throws {
        let (ledger, stream) = ledger()
        ledger.received(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call"}"#.utf8))
        #expect(ledger.inputEnded(drainTimeout: .milliseconds(50)) == 1)
        #expect(try await ends(stream))
    }
}
