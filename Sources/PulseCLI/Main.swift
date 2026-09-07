import Foundation
import Dispatch
import PulseCore
import PulseLoad
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { switch self { case .usage(let message): return message } }
}
struct Arguments {
    let command: String
    var flags: [String: [String]] = [:]
    init(_ values: [String]) throws {
        command = values.first ?? "help"
        var index = 1
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"), index + 1 < values.count else { throw CLIError.usage("Expected --option value: \(key)") }
            flags[key, default: []].append(values[index + 1]); index += 2
        }
    }
    func string(_ key: String, _ fallback: String) -> String { flags[key]?.last ?? fallback }
    func number(_ key: String, _ fallback: Double) throws -> Double {
        guard var text = flags[key]?.last else { return fallback }
        var scale = 1.0
        if text.hasSuffix("ms") { text.removeLast(2); scale = 0.001 }
        else if text.hasSuffix("s") { text.removeLast() }
        else if text.hasSuffix("m") { text.removeLast(); scale = 60 }
        guard let value = Double(text), value.isFinite else { throw CLIError.usage("Invalid number for \(key)") }
        return value * scale
    }
    func integer(_ key: String, _ fallback: Int) throws -> Int {
        guard let text = flags[key]?.last else { return fallback }
        guard let value = Int(text) else { throw CLIError.usage("Invalid integer for \(key)") }; return value
    }
    func allow(_ names: Set<String>) throws {
        if let unknown = flags.keys.first(where: { !names.contains($0) }) { throw CLIError.usage("Unknown option: \(unknown)") }
        if let duplicate = flags.first(where: { $0.key != "--header" && $0.value.count > 1 }) { throw CLIError.usage("Duplicate option: \(duplicate.key)") }
    }
}

func save(_ report: RunReport, to path: String) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: url, options: .atomic)
}
func printSummary(_ report: RunReport) {
    let s = report.summary
    print("Run \(report.id)")
    print("Scheduled \(s.scheduled) | Started \(s.started) | Completed \(s.completed) | Failed \(s.failed) | Dropped \(s.dropped)")
    print(String(format: "Actual start rate %.1f req/s | p50 %.2f ms | p95 %.2f ms | p99 %.2f ms", s.achievedRPS, s.latency.p50, s.latency.p95, s.latency.p99))
    print(String(format: "Schedule-to-completion p99 %.2f ms | Scheduler lag p99 %.2f ms", s.scheduleToCompletion.p99, s.schedulerLag.p99))
    if let error = report.traceError { print("Trace unavailable: \(error)") }
}

@main struct PulseMain {
    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.command == "help" || arguments.command == "--help" { print(help); return }
            let work = Task { try await execute(arguments) }
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number)
                source.setEventHandler { work.cancel() }; source.resume(); return source
            }
            defer { sources.forEach { $0.cancel() } }
            try await work.value
        } catch {
            FileHandle.standardError.write(Data("pulse: \(error)\n".utf8)); exit(1)
        }
    }
    static func execute(_ args: Arguments) async throws {
        switch args.command {
        case "attack":
            try args.allow(["--url", "--method", "--rate", "--duration", "--concurrency", "--timeout", "--header", "--body", "--output", "--trace-url", "--max-lag-ms", "--max-samples", "--max-response-bytes"])
            var config = LoadConfiguration(url: args.string("--url", "http://127.0.0.1:8080/"))
            config.method = args.string("--method", "GET").uppercased()
            config.rate = try args.number("--rate", 100); config.duration = try args.number("--duration", 10)
            config.concurrency = try args.integer("--concurrency", 128); config.timeout = try args.number("--timeout", 5)
            config.maxLagMS = try args.number("--max-lag-ms", 100); config.maxSamples = try args.integer("--max-samples", 20000)
            config.maxResponseBytes = try args.integer("--max-response-bytes", 16_777_216)
            config.traceURL = args.flags["--trace-url"]?.last
            for header in args.flags["--header"] ?? [] {
                guard let colon = header.firstIndex(of: ":") else { throw CLIError.usage("Header must be Name: value") }
                config.headers[String(header[..<colon])] = String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            let body = try args.flags["--body"]?.last.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            let report = try await LoadEngine.run(configuration: config, body: body)
            try save(report, to: args.string("--output", "runs/\(report.id).json")); printSummary(report)
        case "report":
            try args.allow(["--input"])
            let path = args.string("--input", "")
            guard !path.isEmpty else { throw CLIError.usage("report requires --input file.json") }
            printSummary(try JSONDecoder().decode(RunReport.self, from: Data(contentsOf: URL(fileURLWithPath: path))))
        case "serve":
            try args.allow(["--port", "--host", "--workers", "--max-connections", "--trace-capacity", "--timeout"])
            let port = try args.integer("--port", 8080)
            let workers = try args.integer("--workers", 4)
            let maximum = try args.integer("--max-connections", 1024)
            let capacity = try args.integer("--trace-capacity", 100000)
            let timeout = try args.number("--timeout", 15)
            guard (1...65535).contains(port), (1...256).contains(workers), (1...100000).contains(maximum), (0...1_000_000).contains(capacity), timeout > 0, timeout <= 300 else { throw CLIError.usage("Invalid server limits") }
            let recorder = TraceRecorder(capacity: capacity)
            let server = try HTTPServer(address: args.string("--host", "127.0.0.1"), port: UInt16(port), workers: workers, maxConnections: maximum, requestTimeout: timeout, trace: recorder) { request in
                if request.path == "/__pulse/trace" { return try .json(recorder.snapshot()) }
                if request.path == "/echo" { return HTTPResponse(headers: ["Content-Type": "application/octet-stream"], body: request.body) }
                if request.path == "/work" {
                    let items = URLComponents(string: request.target)?.queryItems ?? []
                    func parameter(_ name: String, _ fallback: Int, max maximum: Int) -> Int {
                        max(0, min(maximum, Int(items.first { $0.name == name }?.value ?? "") ?? fallback))
                    }
                    let delay = parameter("delay", 20, max: 5000)
                    let fanout = max(1, parameter("fanout", 2, max: 16))
                    let iterations = parameter("iterations", 10000, max: 10_000_000)
                    let checksum = try await withThrowingTaskGroup(of: UInt64.self) { group in
                        for index in 0..<fanout {
                            group.addTask {
                                try await Task.sleep(for: .milliseconds(delay))
                                var sum = UInt64(index + 1)
                                for i in 0..<iterations {
                                    if i % 4096 == 0 { try Task.checkCancellation() }
                                    sum = (sum &* 1664525) &+ UInt64(i) &+ 1013904223
                                }
                                return sum
                            }
                        }
                        var sum: UInt64 = 0
                        for try await value in group { sum = sum &+ value }
                        return sum
                    }
                    return try .json(["checksum": String(checksum), "fanout": String(fanout)])
                }
                if request.path == "/" || request.path == "/health" { return .text("SwiftPulse OK\n") }
                return .text("Not found", status: 404)
            }
            print("SwiftPulse server http://\(args.string("--host", "127.0.0.1")):\(port) (\(workers) workers)")
            try await server.run()
        case "studio":
            try args.allow(["--port", "--ui-dir", "--reports"])
            let port = try args.integer("--port", 9090)
            guard (1...65535).contains(port) else { throw CLIError.usage("Invalid port") }
            let controller = try StudioController(directory: args.string("--reports", "runs"), uiDirectory: args.string("--ui-dir", "Studio"), port: port)
            let server = try HTTPServer(port: UInt16(port)) { request in try await controller.handle(request) }
            print("SwiftPulse Studio http://127.0.0.1:\(port)")
            do { try await server.run() } catch { await controller.stop(); throw error }
            await controller.stop()
        default: throw CLIError.usage("Unknown command: \(args.command). Use pulse help.")
        }
    }
    static let help = """
    SwiftPulse — nonblocking Swift server, load generator & concurrency studio
    pulse serve [--port 8080] [--workers 4] [--trace-capacity 100000]
    pulse attack --url http://127.0.0.1:8080/work --rate 100 --duration 10s
                 [--concurrency 128] [--timeout 5s] [--method POST] [--body file]
                 [--header 'Name: value'] [--trace-url http://127.0.0.1:8080/__pulse/trace]
                 [--output runs/result.json] [--max-lag-ms 100] [--max-samples 20000]
    pulse report --input runs/result.json
    pulse studio [--port 9090] [--ui-dir Studio] [--reports runs]
    """
}
