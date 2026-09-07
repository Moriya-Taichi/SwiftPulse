import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ProbeResult: Sendable { let status: Int; let bytes: Int; let error: String? }
private final class RequestBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func bind(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
}

/// URLSession's transport is NIO-free. Response bodies are counted and discarded, never accumulated.
final class HTTPProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<ProbeResult, Never>
        var status = 0
        var bytes = 0
        var exceeded = false
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!
    private let maximumBody: Int
    init(configuration: LoadConfiguration) {
        maximumBody = configuration.maxResponseBytes
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = configuration.concurrency
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: callbacks)
    }
    func close() { session.invalidateAndCancel() }
    func perform(_ request: URLRequest) async -> ProbeResult {
        let binding = RequestBinding()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock(); pending[task.taskIdentifier] = Pending(continuation: continuation); lock.unlock()
                binding.bind(task)
                task.resume()
            }
        } onCancel: { binding.cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); pending[dataTask.taskIdentifier]?.status = (response as? HTTPURLResponse)?.statusCode ?? 0; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.bytes += data.count
        let exceeded = (pending[dataTask.taskIdentifier]?.bytes ?? 0) > maximumBody
        if exceeded { pending[dataTask.taskIdentifier]?.exceeded = true }
        lock.unlock()
        if exceeded { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); let result = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let result else { return }
        result.continuation.resume(returning: ProbeResult(status: result.status, bytes: result.bytes,
            error: result.exceeded ? "response_body_limit" : error.map { String(describing: $0) }))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Count the target's response; never silently multiply traffic via redirects.
    }
}
