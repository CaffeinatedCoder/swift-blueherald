public import BlueHeraldCore
import Synchronization

/// A `CaptureSink` that keeps every event in memory, for assertions.
public final class RecordingCapture: CaptureSink {
    public let destination = "memory"
    private let recorded = Mutex<[CaptureEvent]>([])

    public init() {}

    public var events: [CaptureEvent] { recorded.withLock { $0 } }
    public var kinds: [CaptureEvent.Kind] { events.map(\.kind) }

    public func record(_ event: CaptureEvent) {
        recorded.withLock { $0.append(event) }
    }
}
