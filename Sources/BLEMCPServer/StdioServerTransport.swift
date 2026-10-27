#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
public import Foundation
public import Logging
public import MCP
import Synchronization

/// Newline-delimited JSON-RPC over a pair of file descriptors, woken by the kernel instead of
/// polling.
///
/// The SDK's `StdioTransport` switches stdin to non-blocking mode and retries every 10 ms while
/// no input is waiting: about 100 wake-ups a second for an idle server, and up to 10 ms added to
/// every request. Here a dedicated thread sits in a blocking `read`, which costs no CPU while idle
/// and returns the moment data arrives.
///
/// Why a blocking thread rather than a kqueue read source: on macOS, kqueue (and `poll`) report
/// end of file for anonymous pipes but not for named FIFOs, and not reliably for regular files or
/// device nodes. A read source would wait forever on `ble-mcp < fifo`. `read` returning 0 is the
/// one EOF signal every descriptor type gives.
///
/// File descriptor flags are left alone. stdin and stdout are often shared with the launching
/// process (a terminal in particular), and `O_NONBLOCK` set on such a shared description outlives
/// this process. The transport does not own the descriptors and never closes them.
public actor StdioServerTransport: Transport {
    public nonisolated let logger: Logger

    private let input: Int32
    private let output: Int32
    private let writeQueue = DispatchQueue(label: "ble-mcp.stdio.write")
    private let messages: AsyncThrowingStream<Data, any Error>
    private let messageSink: AsyncThrowingStream<Data, any Error>.Continuation
    private let readerState = ReaderState()
    private var isConnected = false

    public init(
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        logger: Logger = Logger(label: "ble-mcp.stdio")
    ) {
        self.input = input
        self.output = output
        self.logger = logger
        (messages, messageSink) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    public func connect() {
        guard !isConnected else { return }
        isConnected = true
        Self.suppressSIGPIPE(on: output)
        let reader = Thread { [input, messageSink, readerState, logger] in
            Self.readLoop(from: input, into: messageSink, state: readerState, logger: logger)
        }
        reader.name = "ble-mcp.stdio.read"
        reader.start()
    }

    public func disconnect() {
        guard isConnected else { return }
        isConnected = false
        // A reader blocked in `read` notices on its next wake-up and delivers nothing more.
        readerState.close()
        messageSink.finish()
    }

    public func send(_ message: Data) async throws {
        guard isConnected else { throw MCPError.connectionClosed }
        let frame = message + Data([UInt8(ascii: "\n")])
        let output = output
        // Enqueued from the actor in call order, so the serial write queue preserves message order.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                continuation.resume(with: Self.writeAll(frame, to: output))
            }
        }
    }

    public nonisolated func receive() -> AsyncThrowingStream<Data, any Error> {
        messages
    }

    // MARK: - Reading (on the reader thread; all state here is thread-local)

    private static func readLoop(
        from descriptor: Int32,
        into sink: AsyncThrowingStream<Data, any Error>.Continuation,
        state: ReaderState,
        logger: Logger
    ) {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !state.isClosed {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard !state.isClosed else { return }
            if count > 0 {
                let result = framer.append(buffer[..<count])
                result.messages.forEach { sink.yield($0) }
                if result.discardedOversizedMessage {
                    logger.error("Discarded an incoming message larger than \(framer.maximumMessageLength) bytes")
                }
                continue
            }
            if count == 0 {
                logger.notice("EOF on stdin")
                sink.finish()
                return
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                // Someone else made the shared descriptor non-blocking: wait for data instead of spinning.
                var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&request, 1, -1)
            case let code:
                sink.finish(throwing: MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))
                return
            }
        }
    }

    // MARK: - Writing (on the write queue)

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Result<Void, any Error> {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    // Someone else made the shared descriptor non-blocking: wait until it drains.
                    var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&request, 1, -1)
                case let code:
                    return .failure(MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))
                }
            }
            return .success(())
        }
    }

    /// A client that exits mid-write must produce `EPIPE`, not a process-killing `SIGPIPE`.
    /// Applied only to pipes and sockets, whose descriptions belong to this client connection.
    private static func suppressSIGPIPE(on descriptor: Int32) {
        #if canImport(Darwin)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return }
        let type = info.st_mode & S_IFMT
        if type == S_IFIFO || type == S_IFSOCK {
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        }
        #endif
    }
}

/// Lets `disconnect` tell the reader thread to stop delivering.
private final class ReaderState: Sendable {
    private let closed = Atomic(false)

    var isClosed: Bool { closed.load(ordering: .acquiring) }

    func close() {
        closed.store(true, ordering: .releasing)
    }
}

/// Splits a byte stream into newline-delimited messages.
///
/// Each byte is scanned once, however the stream is chunked. Lines may end in `\n` or `\r\n`, and
/// blank lines are skipped. A line that grows past `maximumMessageLength` without a newline is
/// discarded up to its next newline, so a misbehaving client cannot exhaust memory.
struct LineFramer {
    struct Output {
        var messages: [Data] = []
        var discardedOversizedMessage = false
    }

    let maximumMessageLength: Int
    private var pending: [UInt8] = []
    private var isDiscarding = false

    init(maximumMessageLength: Int = 16 * 1024 * 1024) {
        self.maximumMessageLength = maximumMessageLength
    }

    mutating func append(_ bytes: some Collection<UInt8>) -> Output {
        var output = Output()
        var lineStart = pending.startIndex
        let scanFrom = pending.endIndex
        pending.append(contentsOf: bytes)

        var index = scanFrom
        while let newline = pending[index...].firstIndex(of: UInt8(ascii: "\n")) {
            if isDiscarding {
                isDiscarding = false
            } else {
                var lineEnd = newline
                if lineEnd > lineStart, pending[lineEnd - 1] == UInt8(ascii: "\r") {
                    lineEnd -= 1
                }
                if lineEnd > lineStart {
                    output.messages.append(Data(pending[lineStart..<lineEnd]))
                }
            }
            lineStart = newline + 1
            index = lineStart
        }
        pending.removeFirst(lineStart)

        if pending.count > maximumMessageLength {
            pending.removeAll(keepingCapacity: false)
            isDiscarding = true
            output.discardedOversizedMessage = true
        } else if isDiscarding {
            pending.removeAll(keepingCapacity: true)
        }
        return output
    }
}
