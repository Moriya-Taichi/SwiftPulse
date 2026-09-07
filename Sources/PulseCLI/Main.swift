import Foundation
import Dispatch
import PulseCore
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

@main struct PulseMain {
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
            ProcessSignals.install()
            let work = Task { try await execute(arguments) }
            let watcher = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(50))
                    if ProcessSignals.received { work.cancel(); return }
                }
            }
            let result = await work.result
            watcher.cancel(); _ = await watcher.result
            ProcessSignals.restore()
            try result.get()
        } catch {
            FileHandle.standardError.write(Data("pulse: \(error)\n".utf8)); exit(1)
        }
    }
    static func execute(_ args: Arguments) async throws {
        switch args.command {
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
                if request.path == "/__pulse/trace" { return try TraceEndpoint.response(to: request, recorder: recorder) }
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
            try args.allow(["--port", "--ui-dir", "--target"])
            let port = try args.integer("--port", 9090)
            guard (1...65535).contains(port) else { throw CLIError.usage("Invalid port") }
            let controller = try StudioController(target: args.string("--target", "http://127.0.0.1:8080"), uiDirectory: args.string("--ui-dir", "Studio"))
            let server = try HTTPServer(port: UInt16(port)) { request in try await controller.handle(request) }
            print("SwiftPulse Studio http://127.0.0.1:\(port)")
            defer { controller.close() }
            try await server.run()
        default: throw CLIError.usage("Unknown command: \(args.command). Use pulse help.")
        }
    }
    static let help = """
    SwiftPulse — nonblocking Swift server with execution observability
    pulse serve [--port 8080] [--workers 4] [--trace-capacity 100000]
                [--host 127.0.0.1] [--max-connections 1024] [--timeout 15s]
    pulse studio [--port 9090] [--target http://127.0.0.1:8080] [--ui-dir Studio]

    Load testing is a separate package: Packages/PulseLoad (pulse-load).
    """
}
