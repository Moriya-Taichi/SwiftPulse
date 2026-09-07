import Foundation
import Testing
@testable import PulseCore
@testable import PulseLoad

@Test func fragmentedAndPipelinedHTTP() throws {
    var bytes = Data("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nab".utf8)
    #expect(try HTTPParser.extract(from: &bytes) == nil)
    bytes.append(Data("cGET /health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
    let first = try HTTPParser.extract(from: &bytes)
    #expect(first?.body == Data("abc".utf8))
    #expect(try HTTPParser.extract(from: &bytes)?.path == "/health")
    #expect(bytes.isEmpty)
}

@Test(arguments: [
    "Host: localhost\r\nContent-Length: 1\r\nContent-Length: 2",
    "Host: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 1",
    "Host: localhost\r\nContent-Length: -1",
    "Host: localhost\r\n Content-Length: 1",
    "Host: localhost\r\nContent-Length: 9999999999999999999999",
    "Host: localhost\r\nX-Test: bad\nvalue",
    "X-Test: missing-host"
]) func rejectAmbiguousFraming(_ headers: String) {
    var bytes = Data("POST / HTTP/1.1\r\n\(headers)\r\n\r\na".utf8)
    #expect(throws: (any Error).self) { try HTTPParser.extract(from: &bytes) }
}

@Test func rejectOversizedBodyBeforeReceivingIt() {
    var bytes = Data("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048577\r\n\r\n".utf8)
    #expect(throws: HTTPError.self) { try HTTPParser.extract(from: &bytes) }
}

@Test func socketRoundTripUnderBackpressure() async throws {
    let (writer, reader) = try AsyncSocket.pair()
    defer { writer.close(); reader.close() }
    let expected = Data((0..<1_048_576).map { UInt8($0 % 251) })
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await writer.write(expected) }
        group.addTask {
            try await Task.sleep(for: .milliseconds(20))
            var received = Data()
            while received.count < expected.count { received.append(try await reader.read(maxBytes: 4096)) }
            #expect(received == expected)
        }
        try await group.waitForAll()
    }
}

@Test func cancelIdleRead() async throws {
    let (a, b) = try AsyncSocket.pair()
    defer { a.close(); b.close() }
    let reader = Task { try await a.read() }
    try await Task.sleep(for: .milliseconds(10))
    reader.cancel()
    switch await reader.result {
    case .failure: break
    case .success: Issue.record("Cancelled read unexpectedly succeeded")
    }
}

@Test func histogramUsesBoundedApproximation() {
    var histogram = LatencyHistogram()
    for i in 1...1000 { histogram.record(Double(i)) }
    #expect(histogram.percentile(0.50) >= 500)
    #expect(histogram.percentile(0.50) <= 510)
    #expect(histogram.percentile(0.99) >= 990)
    #expect(histogram.summary.max == 1000)
    #expect(histogram.summary.mean == 500.5)
}

@Test func traceCapacityIsBounded() {
    let recorder = TraceRecorder(capacity: 2)
    for _ in 0..<5 { recorder.span("test", category: "test", start: monotonicNS(), lane: "test") }
    #expect(recorder.snapshot().traceEvents.count == 2)
    #expect(recorder.snapshot().droppedEvents == 3)
}

@Test func invalidLoadConfiguration() {
    var config = LoadConfiguration(url: "file:///tmp/data")
    #expect(throws: LoadError.self) { try config.validate() }
    config.url = "http://localhost/"; config.rate = .nan
    #expect(throws: LoadError.self) { try config.validate() }
}

@Test func openLoopDropsInsteadOfBecomingClosedLoop() async throws {
    let server = try HTTPServer(port: 0) { _ in
        try await Task.sleep(for: .milliseconds(100)); return .text("ok")
    }
    let running = Task { try await server.run() }
    defer { server.stop(); running.cancel() }
    var config = LoadConfiguration(url: "http://127.0.0.1:\(await server.listener.localPort())/")
    config.rate = 100; config.duration = 0.5; config.concurrency = 1; config.maxSamples = 2
    let result = try await LoadEngine.run(configuration: config)
    #expect(result.summary.scheduled == 50)
    #expect(result.summary.droppedCapacity > 0)
    #expect(result.summary.started + result.summary.dropped == 50)
    #expect(result.summary.completed == result.summary.started)
    #expect(result.summary.peakInFlight <= 1)
    #expect(result.requests.count <= 2)
    #expect(result.summary.failed == 0)
    server.stop(); running.cancel(); _ = await running.result
}

@Test func loadReportsServerFailures() async throws {
    let server = try HTTPServer(port: 0) { _ in .text("unavailable", status: 503) }
    let running = Task { try await server.run() }
    defer { server.stop(); running.cancel() }
    var config = LoadConfiguration(url: "http://127.0.0.1:\(await server.listener.localPort())/")
    config.rate = 10; config.duration = 0.3
    let report = try await LoadEngine.run(configuration: config)
    #expect(report.summary.completed > 0)
    #expect(report.summary.failed == report.summary.completed)
    #expect(report.summary.statuses["503"] == report.summary.completed)
    server.stop(); running.cancel(); _ = await running.result
}
