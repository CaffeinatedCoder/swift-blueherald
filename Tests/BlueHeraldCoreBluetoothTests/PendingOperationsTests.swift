import BlueHeraldCore
@testable import BlueHeraldCoreBluetooth
import Foundation
import Testing

/// Drives `PendingOperations` the way `CoreBluetoothCentral` does: `perform` enqueues and issues
/// the request, a timeout or cancellation resumes it by token, and the delegate callback hands
/// its result to the oldest request with `resumeFirst`. CoreBluetooth answers every request it
/// was sent, including one given up on.
@Suite("Pending operations")
struct PendingOperationsTests {
    actor Table {
        var pending = PendingOperations()
        let peripheral = PeripheralID(UUID())

        func enqueue(_ key: OperationKey, _ continuation: OperationContinuation) -> UInt64 {
            let token = pending.makeToken()
            pending.enqueue(key, token: token, peripheral: peripheral, continuation: continuation)
            return token
        }

        func giveUp(_ key: OperationKey, _ token: UInt64) -> Bool {
            pending.resume(key, token: token, with: .failure(.cancelled))
        }

        func callback(_ key: OperationKey, _ value: UInt8) -> Bool {
            pending.resumeFirst(key, with: .success(.data(Data([value]))))
        }

        func disconnect() {
            pending.failAll(for: peripheral, with: .disconnected(peripheral, reason: nil))
        }

        func isWaiting(_ key: OperationKey) -> Bool {
            pending.isWaiting(on: key)
        }

        /// Starts a request and returns once it is queued.
        func request(_ key: OperationKey) async -> (token: UInt64, result: Task<Result<Outcome, BLEError>, Never>) {
            let tokens = AsyncStream.makeStream(of: UInt64.self)
            let result = Task {
                await withCheckedContinuation { (continuation: OperationContinuation) in
                    Task { tokens.continuation.yield(self.enqueue(key, continuation)) }
                }
            }
            var iterator = tokens.stream.makeAsyncIterator()
            return (await iterator.next()!, result)
        }
    }

    static let key = OperationKey.read(ObjectIdentifier(NSObject.self))

    func value(_ result: Result<Outcome, BLEError>) throws -> Data? {
        guard case .data(let value) = try result.get() else { return nil }
        return value
    }

    @Test("the late answer to a request given up on does not answer the next one")
    func lateAnswer() async throws {
        let table = Table()
        let first = await table.request(Self.key)
        #expect(await table.giveUp(Self.key, first.token))
        let firstResult = await first.result.value
        #expect(throws: BLEError.cancelled) { try firstResult.get() }

        let second = await table.request(Self.key)
        #expect(await table.isWaiting(Self.key))
        #expect(await table.callback(Self.key, 0x01), "the answer to the first request is used up")
        #expect(await table.isWaiting(Self.key))
        #expect(await table.callback(Self.key, 0x02))
        #expect(try value(await second.result.value) == Data([0x02]))
        #expect(await table.callback(Self.key, 0x03) == false, "nothing is outstanding any more")
    }

    @Test("a disconnect clears placeholders, so the next connection starts clean")
    func disconnectClears() async throws {
        let table = Table()
        let first = await table.request(Self.key)
        _ = await table.giveUp(Self.key, first.token)
        await table.disconnect()
        let second = await table.request(Self.key)
        _ = await table.callback(Self.key, 0x02)
        #expect(try value(await second.result.value) == Data([0x02]))
    }

    @Test("keys whose waiters share one callback leave no placeholder")
    func sharedKeys() async throws {
        let table = Table()
        let key = OperationKey.services(PeripheralID(UUID()))
        let first = await table.request(key)
        _ = await table.giveUp(key, first.token)
        #expect(await table.callback(key, 0x01) == false)
        #expect(OperationKey.write(ObjectIdentifier(NSObject.self)).isAnsweredInOrder)
        #expect(!key.isAnsweredInOrder)
    }

    @Test("giving up twice, or after the answer, resumes nothing")
    func giveUpOnce() async throws {
        let table = Table()
        let first = await table.request(Self.key)
        #expect(await table.giveUp(Self.key, first.token))
        #expect(await table.giveUp(Self.key, first.token) == false)
        let second = await table.request(Self.key)
        _ = await table.callback(Self.key, 0x01)
        _ = await table.callback(Self.key, 0x02)
        _ = await second.result.value
        #expect(await table.giveUp(Self.key, second.token) == false)
    }
}
