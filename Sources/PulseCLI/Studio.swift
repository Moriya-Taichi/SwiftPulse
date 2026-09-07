import Foundation
import PulseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor StudioController {
    private let target: URL
    private let assets: [String: HTTPResponse]
    private let client = TraceClient()
    private var cached: (key: String, at: UInt64, response: HTTPResponse)?
    private var fetching: (key: String, task: Task<HTTPResponse, Never>)?
    init(target: String, uiDirectory: String) throws {
        guard let url = URL(string: target), ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw CLIError.usage("--target must be an HTTP(S) server origin") }
        self.target = url.appendingPathComponent("__pulse/trace")
        var assets: [String: HTTPResponse] = [:]
        for (name, mime) in [("index.html", "text/html"), ("app.js", "text/javascript"), ("model.mjs", "text/javascript"), ("styles.css", "text/css"), ("demo-trace.json", "application/json")] {
            let data = try Data(contentsOf: URL(fileURLWithPath: uiDirectory).appendingPathComponent(name))
            assets["/\(name)"] = HTTPResponse(headers: ["Content-Type": "\(mime); charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"], body: data)
        }
        assets["/"] = assets["/index.html"]; self.assets = assets
    }
    nonisolated func close() { client.close() }
    func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.method == "GET" else { return .text("Method not allowed", status: 405) }
        if let asset = assets[request.path] { return asset }
        if request.path == "/api/status" { return try .json(["target": target.absoluteString]) }
        guard request.path == "/api/trace" else { return .text("Not found", status: 404) }
        let items = URLComponents(string: request.target)?.queryItems ?? []
        var query: [URLQueryItem] = []
        if let value = items.first(where: { $0.name == "after" })?.value {
            guard UInt64(value) != nil else { return .text("Invalid cursor", status: 400) }
            query.append(URLQueryItem(name: "after", value: value))
        }
        if let value = items.first(where: { $0.name == "session" })?.value {
            guard value.count <= 128 else { return .text("Invalid session", status: 400) }
            query.append(URLQueryItem(name: "session", value: value))
        }
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        let url = components.url!, key = url.absoluteString
        if let cached, cached.key == key, monotonicNS() - cached.at < 500_000_000 { return cached.response }
        if let fetching {
            if fetching.key == key { return await fetching.task.value }
            return .text("Observer busy; retry next poll", status: 503)
        }
        let client = client
        let task = Task<HTTPResponse, Never> {
            let result = await client.perform(URLRequest(url: url))
            guard result.status == 200, result.error == nil, let data = result.body else {
                return .text("Trace unavailable. Check the target server and /__pulse/trace route.", status: 503)
            }
            return HTTPResponse(headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
        }
        fetching = (key, task)
        let response = await task.value
        fetching = nil; cached = (key, monotonicNS(), response)
        return response
    }
}
