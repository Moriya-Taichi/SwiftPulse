import Foundation
import Dispatch
import CPulse

public func monotonicNS() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// CLI process lifecycle; the POSIX handler only writes a sig_atomic_t value.
public enum ProcessSignals {
    public static func install() { pulse_install_signals() }
    public static func restore() { pulse_restore_signals() }
    public static var received: Bool { pulse_signal_received() != 0 }
}

public struct TraceEvent: Codable, Sendable {
    public var name: String
    public var cat: String
    public var ph: String = "X"
    public var ts: Double
    public var dur: Double
    public var pid: Int = 1
    public var tid: String
    public var args: [String: String]
}

public struct TraceDocument: Codable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let clock: String
    public let epochMS: Double
    public let traceEvents: [TraceEvent]
    public let droppedEvents: Int
    public let scope: String
}

/// Bounded, opt-in recorder. Jobs are executor wall-time slices, not CPU samples.
public final class TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TraceEvent] = []
    private var dropped = 0
    public let capacity: Int
    public let origin = monotonicNS()
    private let epochMS = Date().timeIntervalSince1970 * 1000
    public init(capacity: Int = 0) { self.capacity = max(0, capacity) }
    public func span(_ name: String, category: String, start: UInt64, end: UInt64 = monotonicNS(),
                     lane: String, args: [String: String] = [:]) {
        guard capacity > 0 else { return }
        let event = TraceEvent(name: name, cat: category,
            ts: Double(start >= origin ? start - origin : 0) / 1000,
            dur: Double(end >= start ? end - start : 0) / 1000, tid: lane, args: args)
        lock.lock(); defer { lock.unlock() }
        guard events.count < capacity else { dropped += 1; return }
        events.append(event)
    }
    public func snapshot() -> TraceDocument {
        lock.lock(); defer { lock.unlock() }
        return TraceDocument(schemaVersion: 1, kind: "swiftpulse.trace", clock: "monotonic-relative-us",
            epochMS: epochMS, traceEvents: events, droppedEvents: dropped,
            scope: "Framework operations and managed executor jobs. Await spans are wall time; CPU scheduling and external executors are not captured.")
    }
}

public final class WorkerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = 0
    private let queues: [DispatchQueue]
    public init(workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        queues = (0..<max(1, workers)).map { DispatchQueue(label: "pulse.worker.\($0)") }
    }
    fileprivate func submit(_ work: @escaping @Sendable (Int) -> Void) {
        lock.lock(); let index = cursor; cursor = (cursor + 1) % queues.count; lock.unlock()
        queues[index].async { work(index) }
    }
}

/// A request-scoped executor makes job/request correlation explicit, without private runtime hooks.
public final class RequestExecutor: TaskExecutor, @unchecked Sendable {
    private let pool: WorkerPool
    private let recorder: TraceRecorder
    private let requestID: String
    public init(pool: WorkerPool, recorder: TraceRecorder, requestID: String) {
        self.pool = pool; self.recorder = recorder; self.requestID = requestID
    }
    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let tracing = recorder.capacity > 0
        let queued = tracing ? monotonicNS() : 0
        pool.submit { [self] worker in
            let start = tracing ? monotonicNS() : 0
            job.runSynchronously(on: self.asUnownedTaskExecutor())
            guard tracing else { return }
            recorder.span("Swift job", category: "executor", start: start, lane: "worker-\(worker)",
                args: ["requestID": requestID, "queueUS": String(Double(start - queued) / 1000),
                       "osThreadID": String(pulse_thread_id())])
        }
    }
}
