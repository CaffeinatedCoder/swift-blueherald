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
/// device nodes. A read source would wait forever on `blueherald < fifo`. `read` returning 0 is the
/// one EOF signal every descriptor type gives.
///
/// End of input does not end the session at once: a client may close stdin right after its last
/// request, the way MCP describes ending a stdio session, and the SDK answers each request from a
/// task of its own. The stream of received messages therefore stays open until every request read
/// so far has been answered or cancelled, or until `drainTimeout` passes.
///
/// File descriptor flags are left alone. stdin and stdout are often shared with the launching
/// process (a terminal in particular), and `O_NONBLOCK` set on such a shared description outlives
/// this process. The transport does not own the descriptors and never closes them.
public actor StdioServerTransport: Transport {
    public nonisolated let logger: Logger

    private let input: Int32
    private let output: Int32
    private let writeQueue = DispatchQueue(label: "blueherald.stdio.write")
    private let messages: AsyncThrowingStream<Data, any Error>
    private let messageSink: AsyncThrowingStream<Data, any Error>.Continuation
    private let readerState = ReaderState()
    private let ledger: RequestLedger
    private let drainTimeout: Duration
    private var isConnected = false

    /// - Parameter drainTimeout: How long, after end of input, requests still being handled get to
    ///   send their responses.
    public init(
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        drainTimeout: Duration = .seconds(30),
        logger: Logger = Logger(label: "blueherald.stdio")
    ) {
        self.input = input
        self.output = output
        self.drainTimeout = drainTimeout
        self.logger = logger
        (messages, messageSink) = AsyncThrowingStream.makeStream(of: Data.self)
        ledger = RequestLedger(sink: messageSink)
    }

    public func connect() {
        guard !isConnected else { return }
        isConnected = true
        Self.suppressSIGPIPE(on: output)
        let reader = Thread { [input, messageSink, readerState, ledger, drainTimeout, logger] in
            Self.readLoop(
                from: input, into: messageSink, state: readerState, ledger: ledger, drainTimeout: drainTimeout, logger: logger)
        }
        reader.name = "blueherald.stdio.read"
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
        let ledger = ledger
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                let result = Self.writeAll(frame, to: output)
                // Answered either way: a response that could not be written never will be.
                ledger.sent(message)
                continuation.resume(with: result)
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
        ledger: RequestLedger,
        drainTimeout: Duration,
        logger: Logger
    ) {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !state.isClosed {
            // read(2) takes a raw pointer; neither the standard library nor System has a Span form.
            // The pointer lives only for the call and the count bounds it.
            let count = buffer.withUnsafeMutableBytes { unsafe read(descriptor, $0.baseAddress, $0.count) }
            guard !state.isClosed else { return }
            if count > 0 {
                let result = framer.append(buffer[..<count])
                for message in result.messages {
                    // Recorded before delivery, so the response cannot be sent before it is expected.
                    ledger.received(message)
                    sink.yield(message)
                }
                if result.discardedOversizedMessage {
                    logger.error("Discarded an incoming message larger than \(framer.maximumMessageLength) bytes")
                }
                continue
            }
            if count == 0 {
                let unanswered = ledger.inputEnded(drainTimeout: drainTimeout)
                logger.notice(unanswered == 0 ? "EOF on stdin" : "EOF on stdin; answering \(unanswered) requests first")
                return
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                // Someone else made the shared descriptor non-blocking: wait for data instead of spinning.
                var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = unsafe poll(&request, 1, -1)
            case let code:
                sink.finish(throwing: MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)))
                return
            }
        }
    }

    // MARK: - Writing (on the write queue)

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Result<Void, any Error> {
        // System's writeAll would hide how much was written before an EAGAIN, so this stays on
        // write(2), whose pointer is bounded by the remaining count.
        unsafe data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = unsafe write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
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
                    _ = unsafe poll(&request, 1, -1)
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
        guard unsafe fstat(descriptor, &info) == 0 else { return }
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

/// The requests read but not answered yet, so that end of input can wait for their responses.
final class RequestLedger: Sendable {
    private struct State {
        var unanswered: Set<ID> = []
        var hasInputEnded = false
    }

    private let state = Mutex(State())
    private let sink: AsyncThrowingStream<Data, any Error>.Continuation

    init(sink: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.sink = sink
    }

    var unansweredCount: Int { state.withLock { $0.unanswered.count } }

    /// Notes the requests in an incoming message, and the ones a cancellation withdraws: the SDK
    /// does not answer a cancelled request.
    func received(_ message: Data) {
        let envelopes = Envelope.decode(message)
        state.withLock { state in
            for envelope in envelopes {
                if envelope.method == "notifications/cancelled", let id = envelope.cancelledRequest {
                    state.unanswered.remove(id)
                } else if envelope.method != nil, let id = envelope.id {
                    state.unanswered.insert(id)
                }
            }
        }
    }

    /// Notes the responses in an outgoing message.
    func sent(_ message: Data) {
        guard unansweredCount > 0 else { return }
        let answered = Envelope.decode(message).compactMap { $0.method == nil ? $0.id : nil }
        guard !answered.isEmpty else { return }
        state.withLock { $0.unanswered.subtract(answered) }
        finishIfDrained()
    }

    /// Ends the stream once every request has been answered, or after `drainTimeout`.
    /// Returns how many requests were still unanswered.
    func inputEnded(drainTimeout: Duration) -> Int {
        let unanswered = state.withLock { state in
            state.hasInputEnded = true
            return state.unanswered.count
        }
        if unanswered == 0 {
            sink.finish()
        } else {
            let sink = sink
            DispatchQueue.global().asyncAfter(deadline: .now() + drainTimeout / .seconds(1)) { sink.finish() }
        }
        return unanswered
    }

    private func finishIfDrained() {
        if state.withLock({ $0.hasInputEnded && $0.unanswered.isEmpty }) {
            sink.finish()
        }
    }

    /// The fields of a JSON-RPC message that tell requests, responses and cancellations apart.
    private struct Envelope: Decodable {
        struct Parameters: Decodable {
            let requestId: ID?
        }

        let id: ID?
        let method: String?
        let params: Parameters?

        var cancelledRequest: ID? { params?.requestId }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(ID.self, forKey: .id)
            method = try? container.decodeIfPresent(String.self, forKey: .method)
            params = try? container.decodeIfPresent(Parameters.self, forKey: .params)
        }

        private enum CodingKeys: String, CodingKey {
            case id, method, params
        }

        /// A message or a batch of them; anything unreadable has no requests.
        static func decode(_ message: Data) -> [Envelope] {
            let decoder = JSONDecoder()
            if message.first(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }) == UInt8(ascii: "[") {
                return (try? decoder.decode([Envelope].self, from: message)) ?? []
            }
            return (try? decoder.decode(Envelope.self, from: message)).map { [$0] } ?? []
        }
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
