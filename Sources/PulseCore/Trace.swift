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
    public var sequence: UInt64? = nil
}

public struct TraceDocument: Codable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let clock: String
    public let epochMS: Double
    public let traceEvents: [TraceEvent]
    public let droppedEvents: Int
    public let scope: String
    public var sessionID: String? = nil
    public var nextCursor: UInt64? = nil
    public var oldestCursor: UInt64? = nil
}

/// Bounded, opt-in ring: retain the latest spans, including after capacity is reached.
/// Snapshots copy only the requested window, so readers do not trigger whole-ring CoW.
public final class TraceRecorder: @unchecked Sendable {
    private enum Payload {
        case fields([String: String])
        case job(requestID: String, queueNS: UInt64, threadID: UInt64)
        var fields: [String: String] {
            switch self {
            case .fields(let args): return args
            case .job(let id, let queued, let thread):
                return ["requestID": id, "queueUS": String(Double(queued) / 1000), "osThreadID": String(thread)]
            }
        }
    }
    private struct Span {
        let name: String, category: String, lane: String
        let start: UInt64, end: UInt64, sequence: UInt64
        let payload: Payload
    }
    private let lock = NSLock()
    private var events: [Span] = []
    private var cursor: UInt64 = 0
    public let capacity: Int
    public let origin = monotonicNS()
    private let epochMS = Date().timeIntervalSince1970 * 1000
    private let sessionID = UUID().uuidString
    public init(capacity: Int = 0) {
        self.capacity = max(0, capacity)
        events.reserveCapacity(min(self.capacity, 4096))
    }
    public func span(_ name: String, category: String, start: UInt64, end: UInt64? = nil,
                     lane: @autoclosure () -> String, args: @autoclosure () -> [String: String] = [:]) {
        guard capacity > 0 else { return }
        append(name, category: category, start: start, end: end ?? monotonicNS(), lane: lane(), payload: .fields(args()))
    }
    fileprivate func job(start: UInt64, end: UInt64, lane: String, requestID: String, queued: UInt64) {
        // Keep numeric metadata on the hot path; format only exported events.
        guard capacity > 0 else { return }
        append("Swift job", category: "executor", start: start, end: end, lane: lane,
               payload: .job(requestID: requestID, queueNS: start - queued, threadID: pulse_thread_id()))
    }
    private func append(_ name: String, category: String, start: UInt64, end: UInt64, lane: String, payload: Payload) {
        lock.lock(); defer { lock.unlock() }
        let event = Span(name: name, category: category, lane: lane, start: start, end: end, sequence: cursor + 1, payload: payload)
        if events.count < capacity { events.append(event) }
        else { events[Int(cursor % UInt64(capacity))] = event }
        cursor += 1
    }
    /// `after` is exclusive. A fresh or lagging consumer gets the newest bounded window.
    public func snapshot(after: UInt64? = nil, limit: Int = .max) -> TraceDocument {
        lock.lock()
        let next = cursor
        let oldest = next - UInt64(events.count) + 1
        let end = Int(min(UInt64(events.count), next > (after ?? 0) ? next - (after ?? 0) : 0))
        let count = min(max(0, limit), end)
        var selected: [Span] = []
        selected.reserveCapacity(count)
        if count > 0 {
            for sequence in (next - UInt64(count) + 1)...next {
                selected.append(events[Int((sequence - 1) % UInt64(capacity))])
            }
        }
        lock.unlock()
        let converted = selected.map { span in
            TraceEvent(name: span.name, cat: span.category,
                ts: Double(span.start >= origin ? span.start - origin : 0) / 1000,
                dur: Double(span.end >= span.start ? span.end - span.start : 0) / 1000,
                tid: span.lane, args: span.payload.fields, sequence: span.sequence)
        }
        return TraceDocument(schemaVersion: 1, kind: "swiftpulse.trace", clock: "monotonic-relative-us", epochMS: epochMS,
            traceEvents: converted, droppedEvents: Int(next - UInt64(min(capacity, Int(next)))),
            scope: "Managed executor wall-time slices and framework operations. OS preemption is included; CPU utilization and external executors are not measured.",
            sessionID: sessionID, nextCursor: next, oldestCursor: oldest)
    }
}

public final class WorkerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = 0
    private let queues: [DispatchQueue]
    private let lanes: [String]
    public init(workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        queues = (0..<max(1, workers)).map { DispatchQueue(label: "pulse.worker.\($0)") }
        lanes = (0..<max(1, workers)).map { "worker-\($0)" }
    }
    fileprivate func submit(_ work: @escaping @Sendable (String) -> Void) {
        lock.lock(); let index = cursor; cursor = (cursor + 1) % queues.count; lock.unlock()
        let lane = lanes[index]
        queues[index].async { work(lane) }
    }
}

/// Request-scoped executor: explicit correlation without private runtime hooks.
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
        pool.submit { [self] lane in
            let start = tracing ? monotonicNS() : 0
            job.runSynchronously(on: self.asUnownedTaskExecutor())
            if tracing { recorder.job(start: start, end: monotonicNS(), lane: lane, requestID: requestID, queued: queued) }
        }
    }
}

/// Add this route to a development server to make it observable by Studio.
public enum TraceEndpoint {
    public static func response(to request: HTTPRequest, recorder: TraceRecorder) throws -> HTTPResponse {
        guard request.method == "GET" else { return .text("Method not allowed", status: 405) }
        let items = URLComponents(string: request.target)?.queryItems ?? []
        var after: UInt64?
        if let raw = items.first(where: { $0.name == "after" })?.value {
            guard let value = UInt64(raw) else { return .text("Invalid cursor", status: 400) }
            after = value
        }
        // A restarted server has a new clock/cursor domain; ignore the previous session's cursor.
        if let session = items.first(where: { $0.name == "session" })?.value, session != recorder.sessionIdentifier { after = nil }
        var response = try HTTPResponse.json(recorder.snapshot(after: after, limit: 5000))
        response.headers["Cache-Control"] = "no-store"
        return response
    }
}

extension TraceRecorder {
    fileprivate var sessionIdentifier: String { sessionID }
}
