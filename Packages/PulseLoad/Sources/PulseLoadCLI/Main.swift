import Foundation
import Dispatch
import CLoadSignals
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
}

@main struct PulseLoadMain {
    static func main() {
        // Keep the process entry thread alive. This wait is NOT on Swift's cooperative pool.
        let finished = DispatchSemaphore(value: 0)
        Task.detached { await run(); finished.signal() }
        finished.wait()
    }
    static func run() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            if arguments.command == "help" || arguments.command == "--help" { print(help); return }
            if arguments.command == "report" { try await execute(arguments); return }
            load_install_signals()
            let work = Task { try await execute(arguments) }
            let watcher = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(50))
                    if load_signal_received() != 0 { work.cancel(); return }
                }
            }
            let result = await work.result
            watcher.cancel(); _ = await watcher.result
            load_restore_signals()
            try result.get()
        } catch {
            FileHandle.standardError.write(Data("pulse-load: \(error)\n".utf8)); exit(1)
        }
    }
    static func execute(_ args: Arguments) async throws {
        switch args.command {
        case "attack":
            try args.allow(["--url", "--method", "--rate", "--duration", "--concurrency", "--timeout", "--header", "--body", "--output", "--max-lag-ms", "--max-samples", "--max-response-bytes"])
            var config = LoadConfiguration(url: args.string("--url", "http://127.0.0.1:8080/"))
            config.method = args.string("--method", "GET").uppercased()
            config.rate = try args.number("--rate", 100); config.duration = try args.number("--duration", 10)
            config.concurrency = try args.integer("--concurrency", 128); config.timeout = try args.number("--timeout", 5)
            config.maxLagMS = try args.number("--max-lag-ms", 100); config.maxSamples = try args.integer("--max-samples", 20000)
            config.maxResponseBytes = try args.integer("--max-response-bytes", 16_777_216)
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
        case "compare":
            try args.allow(["--input", "--baseline"])
            func read(_ key: String) throws -> RunReport {
                let path = args.string(key, "")
                guard !path.isEmpty else { throw CLIError.usage("compare requires --input and --baseline") }
                return try JSONDecoder().decode(RunReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            }
            let current = try read("--input"), baseline = try read("--baseline")
            printSummary(current)
            func delta(_ value: Double, _ base: Double) -> String {
                base == 0 ? "n/a (baseline is zero)" : String(format: "%+.2f%%", (value - base) / base * 100)
            }
            print("Against \(baseline.id): p99 \(delta(current.summary.latency.p99, baseline.summary.latency.p99)); start rate \(delta(current.summary.achievedRPS, baseline.summary.achievedRPS))")
            print("Compare equivalent targets, payloads, rates, concurrency and duration; this command does not establish equivalence.")
        default: throw CLIError.usage("Unknown command: \(args.command). Use pulse-load help.")
        }
    }
    static let help = """
    PulseLoad — standalone constant-rate HTTP load testing
    pulse-load attack --url http://127.0.0.1:8080/ --rate 100 --duration 10s
                      [--concurrency 128] [--timeout 5s] [--method POST] [--body file]
                      [--header 'Name: value'] [--output runs/result.json]
                      [--max-lag-ms 100] [--max-samples 20000] [--max-response-bytes 16777216]
    pulse-load report --input runs/result.json
    pulse-load compare --input runs/current.json --baseline runs/baseline.json
    """
}
