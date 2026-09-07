import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PulseCore

private actor LoadState {
    var summary = LoadSummary()
    var inFlight = 0
    var requests: [RequestSample] = []
    var buckets: [Int: TimeBucket] = [:]
    var latency = LatencyHistogram()
    var total = LatencyHistogram()
    var lag = LatencyHistogram()
    let config: LoadConfiguration
    init(_ config: LoadConfiguration) { self.config = config }
    func reserve(scheduledMS: Double, nowMS: Double) -> Bool {
        summary.scheduled += 1
        let second = Int(scheduledMS / 1000)
        buckets[second, default: TimeBucket(second: second)].scheduled += 1
        if nowMS - scheduledMS > config.maxLagMS {
            summary.droppedLate += 1; buckets[second]!.dropped += 1; return false
        }
        if inFlight >= config.concurrency {
            summary.droppedCapacity += 1; buckets[second]!.dropped += 1; return false
        }
        inFlight += 1; summary.started += 1; summary.peakInFlight = max(summary.peakInFlight, inFlight)
        buckets[second]!.started += 1
        return true
    }
    func finish(_ sample: RequestSample) {
        inFlight -= 1; summary.completed += 1; summary.bytes += sample.bytes
        let failure = sample.error != nil || !(200..<400).contains(sample.status)
        if failure { summary.failed += 1 }
        summary.statuses[String(sample.status), default: 0] += 1
        latency.record(sample.latencyMS); total.record(sample.totalMS); lag.record(sample.lagMS)
        let second = Int(sample.endedMS / 1000)
        buckets[second, default: TimeBucket(second: second)].completed += 1
        buckets[second]!.failed += failure ? 1 : 0
        buckets[second]!.latencySumMS += sample.latencyMS
        buckets[second]!.latencyMaxMS = max(buckets[second]!.latencyMaxMS, sample.latencyMS)
        if requests.count < config.maxSamples { requests.append(sample) }
    }
    func snapshot(elapsed: Double, cancelled: Bool = false) -> LoadSummary {
        var result = summary
        result.elapsed = elapsed; result.cancelled = cancelled
        result.achievedRPS = Double(summary.started) / max(0.000001, min(config.duration, elapsed))
        result.successRate = summary.completed == 0 ? 0 : Double(summary.completed - summary.failed) / Double(summary.completed)
        result.latency = latency.summary; result.scheduleToCompletion = total.summary; result.schedulerLag = lag.summary
        result.sampleCount = requests.count
        return result
    }
    func report(id: String, epoch: Double, elapsed: Double, cancelled: Bool) -> RunReport {
        RunReport(schemaVersion: 1, kind: "swiftpulse.run", id: id, startedAtEpochMS: epoch,
            configuration: config, summary: snapshot(elapsed: elapsed, cancelled: cancelled),
            buckets: buckets.values.sorted { $0.second < $1.second }, requests: requests.sorted { $0.sequence < $1.sequence })
    }
}

public enum LoadEngine {
    /// Open-loop scheduler. Saturation drops slots; it NEVER waits for a response to schedule the next slot.
    public static func run(configuration: LoadConfiguration, body: Data? = nil, id: String = UUID().uuidString,
                           progress: @escaping @Sendable (LoadSummary) async -> Void = { _ in }) async throws -> RunReport {
        try configuration.validate()
        let state = LoadState(configuration)
        let probe = HTTPProbe(configuration: configuration)
        defer { probe.close() }
        let origin = monotonicNS()
        let epoch = Date().timeIntervalSince1970 * 1000
        let count = Int(ceil(configuration.rate * configuration.duration))
        var lastProgress = origin
        await withDiscardingTaskGroup { group in
            for sequence in 0..<count {
                if Task.isCancelled { break }
                let scheduledMS = Double(sequence) / configuration.rate * 1000
                let deadline = origin + UInt64(scheduledMS * 1_000_000)
                let before = monotonicNS()
                if deadline > before {
                    do { try await Task.sleep(nanoseconds: deadline - before) } catch { break }
                }
                let now = monotonicNS()
                if now - lastProgress >= 250_000_000 {
                    await progress(await state.snapshot(elapsed: Double(now - origin) / 1e9)); lastProgress = now
                }
                guard await state.reserve(scheduledMS: scheduledMS, nowMS: Double(now - origin) / 1e6) else { continue }
                group.addTask {
                    let started = monotonicNS()
                    var request = URLRequest(url: URL(string: configuration.url)!)
                    request.httpMethod = configuration.method; request.httpBody = body
                    request.timeoutInterval = configuration.timeout
                    for (key, value) in configuration.headers { request.setValue(value, forHTTPHeaderField: key) }
                    let requestID = "\(id):\(sequence)"
                    request.setValue(requestID, forHTTPHeaderField: "X-Pulse-Request-ID")
                    let result = await probe.perform(request)
                    let ended = monotonicNS()
                    let startedMS = Double(started - origin) / 1e6
                    let endedMS = Double(ended - origin) / 1e6
                    await state.finish(RequestSample(id: requestID, sequence: sequence, scheduledMS: scheduledMS,
                        startedMS: startedMS, endedMS: endedMS, latencyMS: Double(ended - started) / 1e6,
                        lagMS: max(0, startedMS - scheduledMS), totalMS: max(0, endedMS - scheduledMS),
                        status: result.status, bytes: result.bytes, error: result.error))
                }
            }
            // Preserve the full issuance window, including the interval after its final slot.
            let windowEnd = origin + UInt64(configuration.duration * 1e9)
            let now = monotonicNS()
            if !Task.isCancelled && now < windowEnd { try? await Task.sleep(nanoseconds: windowEnd - now) }
            if Task.isCancelled { group.cancelAll() }
        }
        var report = await state.report(id: id, epoch: epoch, elapsed: Double(monotonicNS() - origin) / 1e9, cancelled: Task.isCancelled)
        if let traceURL = configuration.traceURL, !Task.isCancelled {
            do {
                guard let url = URL(string: traceURL), ["http", "https"].contains(url.scheme ?? "") else { throw LoadError.invalidConfiguration }
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForResource = 10
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LoadError.invalidConfiguration }
                report.serverTrace = try JSONDecoder().decode(TraceDocument.self, from: data)
            } catch { report.traceError = String(describing: error) }
        }
        await progress(report.summary)
        return report
    }
}
