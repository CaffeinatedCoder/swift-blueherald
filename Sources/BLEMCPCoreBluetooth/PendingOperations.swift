#if canImport(CoreBluetooth)
import BLEMCPCore
import Foundation

/// What a CoreBluetooth request is waiting for. Attribute-level keys use the object identity of
/// the `CBService`/`CBCharacteristic`/`CBDescriptor`, which CoreBluetooth keeps stable for the
/// lifetime of a connection.
enum OperationKey: Hashable {
    case poweredOn
    case connect(PeripheralID)
    case services(PeripheralID)
    case characteristics(ObjectIdentifier)
    case descriptors(ObjectIdentifier)
    case read(ObjectIdentifier)
    case write(ObjectIdentifier)
    case notify(ObjectIdentifier)
    case readDescriptor(ObjectIdentifier)
    case writeDescriptor(ObjectIdentifier)
    case rssi(PeripheralID)
    case writeWithoutResponseReady(PeripheralID)

    /// Whether CoreBluetooth answers every request on this key with exactly one callback, in
    /// request order. Waiters on the other keys share whatever callback comes next.
    var isAnsweredInOrder: Bool {
        switch self {
        case .read, .write, .notify, .readDescriptor, .writeDescriptor, .rssi: true
        case .poweredOn, .connect, .services, .characteristics, .descriptors, .writeWithoutResponseReady: false
        }
    }
}

enum Outcome: Sendable {
    case done
    case data(Data)
    case rssi(Int)
}

typealias OperationContinuation = CheckedContinuation<Result<Outcome, BLEError>, Never>

/// FIFO queues of continuations waiting on delegate callbacks.
///
/// Every continuation is removed from the table before it is resumed, so a callback, a
/// cancellation and a disconnect racing for the same operation can resume it at most once.
///
/// CoreBluetooth cannot withdraw a request it has sent, so a request given up on (timed out or
/// cancelled) is still answered later. On keys answered in order its entry stays queued as a
/// placeholder with no continuation, and that late callback is used up on it instead of answering
/// the next request with the previous one's value. A disconnect clears placeholders with the rest.
struct PendingOperations {
    private struct Entry {
        let token: UInt64
        let peripheral: PeripheralID?
        /// `nil` for a request given up on that CoreBluetooth still owes a callback.
        let continuation: OperationContinuation?
    }

    private var queues: [OperationKey: [Entry]] = [:]
    private var lastToken: UInt64 = 0

    mutating func makeToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }

    func isWaiting(on key: OperationKey) -> Bool {
        queues[key]?.contains { $0.continuation != nil } == true
    }

    mutating func enqueue(
        _ key: OperationKey,
        token: UInt64,
        peripheral: PeripheralID?,
        continuation: OperationContinuation
    ) {
        queues[key, default: []].append(Entry(token: token, peripheral: peripheral, continuation: continuation))
    }

    /// Hands a callback to the oldest request on `key`: resumes its waiter, or drops the callback
    /// if that request was given up on. Returns `false` when no request was outstanding.
    @discardableResult
    mutating func resumeFirst(_ key: OperationKey, with result: Result<Outcome, BLEError>) -> Bool {
        guard var queue = queues[key], !queue.isEmpty else { return false }
        let entry = queue.removeFirst()
        queues[key] = queue.isEmpty ? nil : queue
        entry.continuation?.resume(returning: result)
        return true
    }

    mutating func resumeAll(_ key: OperationKey, with result: Result<Outcome, BLEError>) {
        guard let queue = queues.removeValue(forKey: key) else { return }
        queue.forEach { $0.continuation?.resume(returning: result) }
    }

    /// Resumes one specific waiter, used for cancellation. On a key answered in order, its entry
    /// stays as a placeholder for the callback still to come. Returns `false` if it already finished.
    @discardableResult
    mutating func resume(_ key: OperationKey, token: UInt64, with result: Result<Outcome, BLEError>) -> Bool {
        guard var queue = queues[key],
            let index = queue.firstIndex(where: { $0.token == token }),
            let continuation = queue[index].continuation
        else { return false }
        if key.isAnsweredInOrder {
            queue[index] = Entry(token: token, peripheral: queue[index].peripheral, continuation: nil)
        } else {
            queue.remove(at: index)
        }
        queues[key] = queue.isEmpty ? nil : queue
        continuation.resume(returning: result)
        return true
    }

    /// Fails every operation that belongs to `peripheral`.
    mutating func failAll(for peripheral: PeripheralID, with error: BLEError) {
        for (key, queue) in queues {
            let (affected, remaining) = queue.reduce(into: ([Entry](), [Entry]())) { split, entry in
                if entry.peripheral == peripheral { split.0.append(entry) } else { split.1.append(entry) }
            }
            guard !affected.isEmpty else { continue }
            queues[key] = remaining.isEmpty ? nil : remaining
            affected.forEach { $0.continuation?.resume(returning: .failure(error)) }
        }
    }

    /// Fails every operation tied to a peripheral, leaving adapter-level waiters in place.
    mutating func failAllPeripheralOperations(with error: BLEError) {
        let peripherals = Set(queues.values.flatMap { $0.compactMap(\.peripheral) })
        for peripheral in peripherals {
            failAll(for: peripheral, with: error)
        }
    }
}
#endif
