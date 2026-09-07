import Foundation
import Testing
@testable import PulseCore

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


@Test func cancelBackpressuredWrite() async throws {
    let (a, b) = try AsyncSocket.pair()
    defer { a.close(); b.close() }
    let writer = Task { try await a.write(Data(repeating: 1, count: 1_048_576)) }
    try await Task.sleep(for: .milliseconds(20))
    writer.cancel()
    _ = await writer.result // Cancellation must release a writer even when the peer never reads.
}


@Test func traceCapacityIsBounded() {
    let recorder = TraceRecorder(capacity: 2)
    for _ in 0..<5 { recorder.span("test", category: "test", start: monotonicNS(), lane: "test") }
    #expect(recorder.snapshot().traceEvents.count == 2)
    #expect(recorder.snapshot().droppedEvents == 3)
}




@Test func decoderHandlesEveryHeaderSplitAndLargePipelinedBodies() throws {
    let header = Data("POST /echo?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\n".utf8)
    for split in 0...header.count {
        var decoder = HTTPDecoder()
        decoder.append(header.prefix(split)); #expect(try decoder.next() == nil)
        decoder.append(header.dropFirst(split)); #expect(try decoder.next() == nil)
        decoder.append(Data("abcGET /next HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
        let decoded = try decoder.next()
        let request = try #require(decoded)
        #expect(request.body == Data("abc".utf8)); #expect(request.path == "/echo")
        #expect(request.requestID == request.requestID)
        #expect(try decoder.next()?.path == "/next"); #expect(try decoder.next() == nil)
    }
    var decoder = HTTPDecoder()
    decoder.append(Data("POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n".utf8))
    let chunk = Data(repeating: 97, count: 1024)
    for _ in 0..<1023 { decoder.append(chunk); #expect(try decoder.next() == nil) }
    decoder.append(chunk)
    decoder.append(Data("GET /next HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
    #expect(try decoder.next()?.body == Data(repeating: 97, count: 1048576))
    #expect(try decoder.next()?.path == "/next")
}

@Test func traceRingExportsLatestSpansAndCursorGaps() {
    let trace = TraceRecorder(capacity: 3)
    for i in 1...8 { trace.span("span-\(i)", category: "test", start: monotonicNS(), lane: "test") }
    let full = trace.snapshot()
    #expect(full.traceEvents.map(\.name) == ["span-6", "span-7", "span-8"])
    #expect(full.droppedEvents == 5); #expect(full.oldestCursor == 6); #expect(full.nextCursor == 8)
    #expect(trace.snapshot(after: 7).traceEvents.map(\.sequence) == [8])
    #expect(trace.snapshot(after: 8).traceEvents.isEmpty)
    #expect(trace.snapshot(after: 0, limit: 2).traceEvents.map(\.sequence) == [7, 8])
    #expect(trace.snapshot(limit: 0).traceEvents.isEmpty)
}

@Test func disabledTracingDoesNotConstructMetadata() {
    let trace = TraceRecorder()
    trace.span("test", category: "test", start: 0, lane: { Issue.record("Disabled tracing evaluated lane"); return "test" }(), args: { Issue.record("Disabled tracing evaluated args"); return [:] }())
    #expect(trace.snapshot().traceEvents.isEmpty)
}

@Test func multiBufferWritePreservesOrderUnderBackpressure() async throws {
    let (writer, reader) = try AsyncSocket.pair()
    defer { writer.close(); reader.close() }
    let buffers = [Data(), Data(repeating: 1, count: 700000), Data(repeating: 2, count: 900000), Data()]
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await writer.write(buffers: buffers) }
        group.addTask {
            try await Task.sleep(for: .milliseconds(20))
            var result = Data()
            while result.count < 1600000 { result.append(try await reader.read(maxBytes: 16384)) }
            #expect(result == buffers.reduce(into: Data(), { $0.append($1) }))
        }
        try await group.waitForAll()
    }
}
