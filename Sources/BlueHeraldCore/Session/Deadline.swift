/// Runs `operation` and cancels it if it has not finished within `limit`.
///
/// The deadline is enforced by cancellation, so the operation must honour it (see the
/// `BLECentral` contract). The losing child is awaited before returning, which means no work
/// outlives the call.
///
/// `operation` is untyped because closure literals do not infer typed throws yet; this is the
/// boundary where every error is normalised back into `BLEError`.
func withDeadline<Success: Sendable>(
    _ limit: Duration,
    operation name: String,
    _ operation: @escaping @Sendable () async throws -> Success
) async throws(BLEError) -> Success {
    do {
        return try await withThrowingTaskGroup(of: Success.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw BLEError.timedOut(operation: name, after: limit)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BLEError.cancelled }
            return first
        }
    } catch {
        throw BLEError(normalising: error)
    }
}

extension BLEError {
    /// Maps any error into the domain: `BLEError` passes through, cancellation becomes
    /// `.cancelled`, anything else is a backend failure.
    init(normalising error: any Error) {
        switch error {
        case let error as BLEError: self = error
        case is CancellationError: self = .cancelled
        default: self = .backendFailure(String(describing: error))
        }
    }
}
