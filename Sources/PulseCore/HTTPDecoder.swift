import Foundation

/// Incremental framing. Scan each header byte once and parse each header once,
/// even if the body arrives over hundreds of reads. Offset consumption avoids
/// repeatedly shifting pipelined input; compaction happens only between requests.
public struct HTTPDecoder: Sendable {
    private var buffer = Data()
    private var offset = 0
    private var scan = 0
    private var pending: (head: HTTPParser.Head, bodyStart: Int)?
    private let maxHeader: Int
    private let maxBody: Int
    public private(set) var consumedBytes = 0
    public init(maxHeader: Int = 16384, maxBody: Int = 1_048_576) {
        self.maxHeader = max(0, maxHeader); self.maxBody = max(0, maxBody)
    }
    public mutating func append(_ data: Data) { buffer.append(data) }
    public mutating func next() throws -> HTTPRequest? {
        if pending == nil {
            let end: Int? = buffer.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let bound = min(bytes.count, offset + maxHeader)
                var i = scan
                while i + 3 < bound {
                    if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i + 4 }
                    i += 1
                }
                return nil
            }
            guard let end else {
                if buffer.count - offset >= maxHeader { throw HTTPError.headerTooLarge }
                scan = max(offset, buffer.count - 3)
                return nil
            }
            let data = Data(buffer.dropFirst(offset).prefix(end - offset - 4))
            pending = (try HTTPParser.parseHead(data, maxBody: maxBody), end)
        }
        guard let pending, buffer.count - pending.bodyStart >= pending.head.length else { return nil }
        let head = pending.head
        let body = Data(buffer.dropFirst(pending.bodyStart).prefix(head.length))
        let end = pending.bodyStart + head.length
        consumedBytes += end - offset
        offset = end; scan = end; self.pending = nil
        if offset == buffer.count { buffer.removeAll(keepingCapacity: true); offset = 0; scan = 0 }
        else if offset >= 65536 { buffer = Data(buffer.dropFirst(offset)); offset = 0; scan = 0 }
        return HTTPRequest(method: head.method, target: head.target, headers: head.headers, body: body)
    }
}
