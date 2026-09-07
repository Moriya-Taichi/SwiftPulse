import Foundation
import PulseCore

public struct LoadConfiguration: Codable, Sendable {
    public var url: String
    public var method: String = "GET"
    public var headers: [String: String] = [:]
    public var rate: Double = 100
    public var duration: Double = 10
    public var concurrency: Int = 128
    public var timeout: Double = 5
    public var maxLagMS: Double = 100
    public var maxSamples: Int = 20000
    public var maxResponseBytes: Int = 16_777_216
    public var traceURL: String? = nil
    public init(url: String) { self.url = url }
    public func validate() throws {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil,
              rate.isFinite, rate > 0, rate <= 100000, duration.isFinite, duration > 0, duration <= 3600,
              rate * duration <= 10_000_000, (1...10000).contains(concurrency), timeout.isFinite, timeout > 0, timeout <= 300,
              maxLagMS.isFinite, maxLagMS >= 0, maxLagMS <= 60000, (0...1_000_000).contains(maxSamples),
              (1...1_073_741_824).contains(maxResponseBytes), !method.isEmpty,
              method.utf8.allSatisfy({ (65...90).contains($0) }) else { throw LoadError.invalidConfiguration }
        for (key, value) in headers {
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == ":" }), !value.contains("\r"), !value.contains("\n") else { throw LoadError.invalidConfiguration }
        }
    }
}
public enum LoadError: Error { case invalidConfiguration }
public struct RequestSample: Codable, Sendable {
    public let id: String
    public let sequence: Int
    public let scheduledMS: Double
    public let startedMS: Double
    public let endedMS: Double
    public let latencyMS: Double
    public let lagMS: Double
    public let totalMS: Double
    public let status: Int
    public let bytes: Int
    public let error: String?
}
public struct Percentiles: Codable, Sendable {
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let max: Double
    public let mean: Double
}
public struct LoadSummary: Codable, Sendable {
    public var scheduled = 0
    public var started = 0
    public var completed = 0
    public var failed = 0
    public var droppedCapacity = 0
    public var droppedLate = 0
    public var peakInFlight = 0
    public var bytes = 0
    public var elapsed = 0.0
    public var cancelled = false
    public var achievedRPS = 0.0
    public var successRate = 0.0
    public var sampleCount = 0
    public var latency: Percentiles = .init(p50: 0, p95: 0, p99: 0, max: 0, mean: 0)
    public var scheduleToCompletion: Percentiles = .init(p50: 0, p95: 0, p99: 0, max: 0, mean: 0)
    public var schedulerLag: Percentiles = .init(p50: 0, p95: 0, p99: 0, max: 0, mean: 0)
    public var statuses: [String: Int] = [:]
    public var dropped: Int { droppedCapacity + droppedLate }
}
public struct TimeBucket: Codable, Sendable {
    public let second: Int
    public var scheduled = 0
    public var started = 0
    public var completed = 0
    public var failed = 0
    public var dropped = 0
    public var latencySumMS = 0.0
    public var latencyMaxMS = 0.0
}
public struct RunReport: Codable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let id: String
    public let startedAtEpochMS: Double
    public let configuration: LoadConfiguration
    public let summary: LoadSummary
    public let buckets: [TimeBucket]
    public let requests: [RequestSample]
    public var serverTrace: TraceDocument?
    public var traceError: String?
}

/// Fixed memory; nearest-rank estimates use upper bucket edges (<=2% relative quantization above 1us).
public struct LatencyHistogram: Sendable {
    private var bins = [Int](repeating: 0, count: 1600)
    private var count = 0
    private var sum = 0.0
    private var maximum = 0.0
    public init() {}
    public mutating func record(_ milliseconds: Double) {
        let value = max(0, milliseconds)
        let index = min(bins.count - 1, max(0, Int(ceil(log(max(1, value * 1000)) / log(1.02)))))
        bins[index] += 1; count += 1; sum += value; maximum = max(maximum, value)
    }
    public func percentile(_ q: Double) -> Double {
        guard count > 0 else { return 0 }
        let rank = max(1, Int(ceil(Double(count) * min(1, max(0, q)))))
        var accumulated = 0
        for (index, value) in bins.enumerated() {
            accumulated += value
            if accumulated >= rank { return min(maximum, pow(1.02, Double(index)) / 1000) }
        }
        return maximum
    }
    public var summary: Percentiles { .init(p50: percentile(0.50), p95: percentile(0.95), p99: percentile(0.99), max: maximum, mean: count == 0 ? 0 : sum / Double(count)) }
}
