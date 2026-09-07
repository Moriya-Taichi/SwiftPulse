import Foundation
import Dispatch
import PulseCore
import PulseLoad

private enum DiskIO {
    static let queue = DispatchQueue(label: "pulse.disk")
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}

actor StudioController {
    private let directory: String
    private let port: Int
    private let assets: [String: HTTPResponse]
    private var reports: [StoredRun] = []
    private var task: Task<Void, Never>?
    private var activeID: String?
    private var summary: LoadSummary?
    private var error: String?
    init(directory: String, uiDirectory: String, port: Int) throws {
        self.directory = directory; self.port = port
        var assets: [String: HTTPResponse] = [:]
        for (name, mime) in [("index.html", "text/html"), ("app.js", "text/javascript"), ("model.mjs", "text/javascript"), ("styles.css", "text/css"), ("demo-run.json", "application/json")] {
            let url = URL(fileURLWithPath: uiDirectory).appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                assets["/\(name)"] = HTTPResponse(headers: ["Content-Type": "\(mime); charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"], body: data)
            }
        }
        guard let index = assets["/index.html"] else { throw CLIError.usage("Studio/index.html not found; use --ui-dir") }
        assets["/"] = index; self.assets = assets
        if let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(20) {
                if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
                   let data = try? Data(contentsOf: file), let report = try? JSONDecoder().decode(RunReport.self, from: data) {
                    reports.append(StoredRun(report, path: file.path))
                }
            }
            reports.sort { $0.index.startedAtEpochMS > $1.index.startedAtEpochMS }
        }
    }
    func stop() async {
        let running = task; running?.cancel(); await running?.value
    }
    private struct Status: Encodable { let activeID: String?; let summary: LoadSummary?; let error: String? }
    private struct RunIndex: Encodable, Sendable { let id: String; let url: String; let startedAtEpochMS: Double; let summary: LoadSummary }
    private struct StoredRun: Sendable {
        let index: RunIndex
        let path: String
        init(_ report: RunReport, path: String) {
            index = RunIndex(id: report.id, url: report.configuration.url, startedAtEpochMS: report.startedAtEpochMS, summary: report.summary)
            self.path = path
        }
    }
    func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.method == "GET", let asset = assets[request.path] { return asset }
        if request.path == "/api/status", request.method == "GET" { return try .json(Status(activeID: activeID, summary: summary, error: error)) }
        if request.path == "/api/runs", request.method == "GET" {
            return try .json(reports.map(\.index))
        }
        if request.path.hasPrefix("/api/runs/"), request.method == "GET" {
            let id = String(request.path.dropFirst("/api/runs/".count))
            guard let stored = reports.first(where: { $0.index.id == id }) else { return .text("Not found", status: 404) }
            let data = try await DiskIO.run { try Data(contentsOf: URL(fileURLWithPath: stored.path)) }
            return HTTPResponse(headers: ["Content-Type": "application/json"], body: data)
        }
        if request.method == "POST", ["/api/attack", "/api/stop"].contains(request.path) {
            if let origin = request.headers["origin"], !["http://127.0.0.1:\(port)", "http://localhost:\(port)"].contains(origin) { return .text("Invalid origin", status: 403) }
            guard request.headers["content-type"]?.hasPrefix("application/json") == true else { return .text("Expected JSON", status: 400) }
            if request.path == "/api/stop" { task?.cancel(); return .text("Stopping") }
            guard activeID == nil else { return .text("A run is already active", status: 409) }
            let config: LoadConfiguration
            do { config = try JSONDecoder().decode(LoadConfiguration.self, from: request.body); try config.validate() }
            catch { return .text("Invalid load configuration: \(error)", status: 422) }
            let id = UUID().uuidString
            activeID = id; summary = nil; error = nil
            task = Task {
                do {
                    let result = try await LoadEngine.run(configuration: config, id: id) { progress in await self.update(progress) }
                    try await DiskIO.run { try save(result, to: "\(self.directory)/\(id).json") }
                    self.reports.insert(StoredRun(result, path: "\(self.directory)/\(id).json"), at: 0)
                    if self.reports.count > 20 { self.reports.removeLast() }
                } catch { self.error = String(describing: error) }
                self.activeID = nil; self.task = nil
            }
            return try .json(["id": id], status: 202)
        }
        return .text("Not found", status: 404)
    }
    private func update(_ progress: LoadSummary) { summary = progress }
}
