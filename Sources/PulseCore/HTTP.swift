import Foundation

public enum HTTPError: Error, Sendable { case badRequest, headerTooLarge, bodyTooLarge, unsupportedTransferEncoding, timeout }
public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data
    public let path: String
    public let requestID: String
    public init(method: String, target: String, headers: [String: String], body: Data = Data()) {
        self.method = method; self.target = target; self.headers = headers; self.body = body
        path = String(target.prefix(while: { $0 != "?" }))
        requestID = headers["x-pulse-request-id"] ?? UUID().uuidString
    }
}
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
    public static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }
    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(value))
    }
}

/// Strict HTTP/1.1 framing: Content-Length only, no TE, no ambiguous duplicates.
public enum HTTPParser {
    public static func extract(from buffer: inout Data, maxHeader: Int = 16384, maxBody: Int = 1_048_576) throws -> HTTPRequest? {
        var decoder = HTTPDecoder(maxHeader: maxHeader, maxBody: maxBody)
        decoder.append(buffer)
        guard let request = try decoder.next() else { return nil }
        buffer.removeFirst(decoder.consumedBytes)
        return request
    }
    struct Head: Sendable { let method: String; let target: String; let headers: [String: String]; let length: Int }
    static func parseHead(_ data: Data, maxBody: Int) throws -> Head {
        guard let text = String(data: data, encoding: .utf8) else { throw HTTPError.badRequest }
        let lines = text.components(separatedBy: "\r\n")
        let line = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard line.count == 3, line[2] == "HTTP/1.1", line[1].hasPrefix("/"),
              !line[1].contains(where: { $0.isWhitespace }), isToken(String(line[0])) else { throw HTTPError.badRequest }
        var headers: [String: String] = [:]
        for item in lines.dropFirst() {
            guard let colon = item.firstIndex(of: ":") else { throw HTTPError.badRequest }
            let name = String(item[..<colon]).lowercased()
            let value = String(item[item.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isToken(name), !value.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || $0.value == 127 }) else { throw HTTPError.badRequest }
            if headers[name] != nil { throw HTTPError.badRequest }
            headers[name] = value
        }
        guard let host = headers["host"], !host.isEmpty else { throw HTTPError.badRequest }
        if headers["transfer-encoding"] != nil { throw HTTPError.unsupportedTransferEncoding }
        if headers["expect"] != nil { throw HTTPError.badRequest }
        if let id = headers["x-pulse-request-id"], id.count > 128 { throw HTTPError.badRequest }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength) else { throw HTTPError.badRequest }
        guard length <= maxBody else { throw HTTPError.bodyTooLarge }
        return Head(method: String(line[0]), target: String(line[1]), headers: headers, length: length)
    }
    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}

private actor ConnectionLimit {
    var count = 0
    let maximum: Int
    init(_ maximum: Int) { self.maximum = maximum }
    func acquire() -> Bool { guard count < maximum else { return false }; count += 1; return true }
    func release() { count -= 1 }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

public final class HTTPServer: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse
    public let listener: AsyncSocket
    public let trace: TraceRecorder
    private let silentTrace = TraceRecorder()
    private let pool: WorkerPool
    private let limit: ConnectionLimit
    private let timeout: Double
    private let handler: Handler
    private let stopFlag = StopFlag()
    public init(address: String = "127.0.0.1", port: UInt16, workers: Int = 4, maxConnections: Int = 1024,
                requestTimeout: Double = 15, trace: TraceRecorder = TraceRecorder(), handler: @escaping Handler) throws {
        guard workers > 0, maxConnections > 0, requestTimeout.isFinite, requestTimeout > 0 else { throw SocketError.limitExceeded }
        listener = try AsyncSocket.listen(address: address, port: port)
        self.trace = trace; pool = WorkerPool(workers: workers); limit = ConnectionLimit(maxConnections)
        timeout = requestTimeout; self.handler = handler
    }
    public func stop() { stopFlag.stop(); listener.close() }
    public func run() async throws {
        try await withTaskCancellationHandler {
            try await withThrowingDiscardingTaskGroup { group in
                while !Task.isCancelled {
                    let socket: AsyncSocket
                    do { socket = try await listener.accept() }
                    catch SocketError.closed { break }
                    if !(await limit.acquire()) { socket.close(); continue }
                    group.addTask {
                        await self.serve(socket)
                        await self.limit.release()
                    }
                }
                if Task.isCancelled { group.cancelAll() }
            }
        } onCancel: { self.listener.close() }
    }
    private func serve(_ socket: AsyncSocket) async {
        defer { socket.close() }
        let tracing = trace.capacity > 0
        let connectionID = tracing ? UUID().uuidString : ""
        let reader = RequestReader()
        do {
            // Bounded keep-alive lifetime prevents an idle client from holding a slot forever.
            for _ in 0..<1000 {
                try Task.checkCancellation()
                if stopFlag.isStopped { return }
                guard let request = try await nextRequest(socket, reader: reader, connectionID: connectionID) else { return }
                let id = request.requestID
                let start = tracing ? monotonicNS() : 0
                let observed = request.path != "/__pulse/trace"
                let executor = RequestExecutor(pool: pool, recorder: observed ? trace : silentTrace, requestID: id)
                let response = try await withTaskExecutorPreference(executor) {
                    try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                        group.addTask { try await self.handler(request) }
                        group.addTask { try await Task.sleep(for: .seconds(self.timeout)); throw HTTPError.timeout }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                }
                let handlerEnd = tracing ? monotonicNS() : 0
                if observed { trace.span("Handler (wall)", category: "handler", start: start, end: handlerEnd, lane: "request:\(id)", args: ["requestID": id, "connectionID": connectionID]) }
                let close = request.headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "close" }) == true
                try await write(response, socket: socket, head: request.method == "HEAD", close: close)
                if observed { trace.span("Response write (wall)", category: "io", start: handlerEnd, lane: "request:\(id)", args: ["requestID": id, "connectionID": connectionID])
                trace.span("Request (wall)", category: "request", start: start, lane: "request:\(id)", args: ["requestID": id, "connectionID": connectionID, "path": request.path, "method": request.method, "status": String(response.status)]) }
                if close { return }
            }
        } catch {
            // Close on malformed framing, cancellation or timeout; never reuse an ambiguous stream.
        }
    }
    // One connection task owns this reader; only its read child mutates it. The deadline child never accesses it.
    private final class RequestReader: @unchecked Sendable { var decoder = HTTPDecoder() }
    private func nextRequest(_ socket: AsyncSocket, reader: RequestReader, connectionID: String) async throws -> HTTPRequest? {
        try await withThrowingTaskGroup(of: HTTPRequest?.self) { group in
            group.addTask {
                while true {
                    if let request = try reader.decoder.next() { return request }
                    let start = self.trace.capacity > 0 ? monotonicNS() : 0
                    let data = try await socket.read()
                    self.trace.span("Socket read (wall)", category: "io", start: start, lane: "connection:\(connectionID)", args: ["connectionID": connectionID])
                    if data.isEmpty { return nil }
                    reader.decoder.append(data)
                }
            }
            group.addTask { try await Task.sleep(for: .seconds(self.timeout)); throw HTTPError.timeout }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func write(_ response: HTTPResponse, socket: AsyncSocket, head: Bool, close: Bool) async throws {
        let reasons = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 422: "Unprocessable Content", 500: "Internal Server Error", 503: "Service Unavailable"]
        var header = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Response")\r\nContent-Length: \(response.body.count)\r\nConnection: \(close ? "close" : "keep-alive")\r\n"
        for (key, value) in response.headers {
            guard !key.contains("\r"), !key.contains("\n"), !value.contains("\r"), !value.contains("\n"),
                  !["content-length", "transfer-encoding", "connection"].contains(key.lowercased()) else { continue }
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        let headerData = Data(header.utf8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                if !head && response.body.count <= 65536 {
                    var packet = headerData
                    packet.append(response.body)
                    try await socket.write(packet)
                    return
                }
                if !head && response.body.count <= 64 * 1024 * 1024 - headerData.count {
                    try await socket.write(buffers: [headerData, response.body])
                    return
                }
                try await socket.write(headerData)
                if !head {
                    for offset in stride(from: 0, to: response.body.count, by: 65536) {
                        try await socket.write(Data(response.body.dropFirst(offset).prefix(65536)))
                    }
                }
            }
            group.addTask { try await Task.sleep(for: .seconds(self.timeout)); throw HTTPError.timeout }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
