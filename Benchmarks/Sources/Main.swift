import Foundation
import PulseCore

let iterations = Int(CommandLine.arguments.dropFirst().first ?? "100") ?? 100
let body = Data(repeating: 97, count: 1024)
let fields = (0..<16).map { "X-Field-\($0): some-header-value-0123456789\r\n" }.joined()
let header = Data("POST /echo HTTP/1.1\r\nHost: localhost\r\n\(fields)Content-Length: 1048576\r\n\r\n".utf8)
var checked = 0
let start = monotonicNS()
for _ in 0..<iterations {
    #if BASELINE
    var buffer = header
    for i in 0..<1024 {
        buffer.append(body)
        let request = try HTTPParser.extract(from: &buffer)
        if i == 1023 { precondition(request?.body.count == 1048576); checked += 1 }
        else { precondition(request == nil) }
    }
    #else
    var decoder = HTTPDecoder()
    decoder.append(header)
    for i in 0..<1024 {
        decoder.append(body)
        let request = try decoder.next()
        if i == 1023 { precondition(request?.body.count == 1048576); checked += 1 }
        else { precondition(request == nil) }
    }
    #endif
}
let ms = Double(monotonicNS() - start) / 1e6
print("{\"scenario\":\"fragmented-1MiB-body-1KiB-chunks\",\"iterations\":\(iterations),\"checked\":\(checked),\"elapsedMS\":\(ms)}")
