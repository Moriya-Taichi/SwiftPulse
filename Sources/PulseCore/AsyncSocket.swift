import Foundation
import Dispatch
import CPulse

public enum SocketError: Error, Sendable, Equatable {
    case system(Int32), closed, concurrentOperation, limitExceeded
}

/// The descriptor closes only after BOTH dispatch sources acknowledge cancellation.
private final class DescriptorLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    private let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func cancelled() {
        lock.lock(); remaining -= 1; let close = remaining == 0; lock.unlock()
        if close { pulse_close(fd) }
    }
}

/// One outstanding read (or accept) and one write. Cancellation closes the socket.
/// All descriptor access/state changes are confined to `queue`; no cooperative thread waits on I/O.
public final class AsyncSocket: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private var reading = false
    private var writing = false
    private var closed = false
    private var readContinuation: CheckedContinuation<Data, any Error>?
    private var acceptContinuation: CheckedContinuation<AsyncSocket, any Error>?
    private var writeContinuation: CheckedContinuation<Void, any Error>?
    private var readSize = 16384
    private var output = Data()
    private var offset = 0

    public init(owningNonblockingDescriptor fd: Int32) {
        self.fd = fd
        queue = DispatchQueue(label: "pulse.socket.\(fd)")
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        let lifetime = DescriptorLifetime(fd)
        readSource.setCancelHandler { lifetime.cancelled() }
        writeSource.setCancelHandler { lifetime.cancelled() }
        readSource.setEventHandler { [weak self] in self?.tryRead() }
        writeSource.setEventHandler { [weak self] in self?.tryWrite() }
    }
    deinit {
        if !closed {
            if !reading { readSource.resume() }
            if !writing { writeSource.resume() }
            readSource.cancel(); writeSource.cancel()
        }
    }
    public static func listen(address: String = "127.0.0.1", port: UInt16, backlog: Int32 = 256) throws -> AsyncSocket {
        let fd = address.withCString { pulse_listen($0, port, backlog) }
        guard fd >= 0 else { throw SocketError.system(pulse_errno()) }
        return AsyncSocket(owningNonblockingDescriptor: fd)
    }
    public static func pair() throws -> (AsyncSocket, AsyncSocket) {
        var descriptors: [Int32] = [0, 0]
        guard pulse_pair(&descriptors) == 0 else { throw SocketError.system(pulse_errno()) }
        return (AsyncSocket(owningNonblockingDescriptor: descriptors[0]), AsyncSocket(owningNonblockingDescriptor: descriptors[1]))
    }
    public func localPort() async -> UInt16 {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.closed ? 0 : pulse_port(self.fd)) } }
    }
    public func close() { queue.async { self.closeOnQueue() } }
    private func closeOnQueue() {
        guard !closed else { return }; closed = true
        if !reading { readSource.resume() }; if !writing { writeSource.resume() }
        readSource.cancel(); writeSource.cancel()
        readContinuation?.resume(throwing: SocketError.closed); readContinuation = nil
        acceptContinuation?.resume(throwing: SocketError.closed); acceptContinuation = nil
        writeContinuation?.resume(throwing: SocketError.closed); writeContinuation = nil
        output = Data()
    }
    public func read(maxBytes: Int = 16384) async throws -> Data {
        guard (1...1_048_576).contains(maxBytes) else { throw SocketError.limitExceeded }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.closed else { continuation.resume(throwing: SocketError.closed); return }
                    guard self.readContinuation == nil && self.acceptContinuation == nil else { continuation.resume(throwing: SocketError.concurrentOperation); return }
                    self.readSize = maxBytes; self.readContinuation = continuation; self.tryRead()
                }
            }
        } onCancel: { self.close() }
    }
    public func accept() async throws -> AsyncSocket {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.closed else { continuation.resume(throwing: SocketError.closed); return }
                    guard self.readContinuation == nil && self.acceptContinuation == nil else { continuation.resume(throwing: SocketError.concurrentOperation); return }
                    self.acceptContinuation = continuation; self.tryRead()
                }
            }
        } onCancel: { self.close() }
    }
    private func stopReading() { if reading { readSource.suspend(); reading = false } }
    private func waitForRead() { if !reading { reading = true; readSource.resume() } }
    private func tryRead() {
        guard !closed else { return }
        if let continuation = acceptContinuation {
            let child = pulse_accept(fd)
            if child >= 0 {
                acceptContinuation = nil; stopReading()
                continuation.resume(returning: AsyncSocket(owningNonblockingDescriptor: child)); return
            }
            let error = pulse_errno()
            if pulse_interrupted(error) != 0 { queue.async { self.tryRead() }; return }
            if pulse_would_block(error) != 0 { waitForRead(); return }
            acceptContinuation = nil; stopReading(); continuation.resume(throwing: SocketError.system(error)); return
        }
        guard let continuation = readContinuation else { stopReading(); return }
        var data = Data(count: readSize)
        let count = data.withUnsafeMutableBytes { pulse_receive(fd, $0.baseAddress!, $0.count) }
        if count >= 0 {
            data.count = count; readContinuation = nil; stopReading(); continuation.resume(returning: data); return
        }
        let error = pulse_errno()
        if pulse_interrupted(error) != 0 { queue.async { self.tryRead() }; return }
        if pulse_would_block(error) != 0 { waitForRead(); return }
        readContinuation = nil; stopReading(); continuation.resume(throwing: SocketError.system(error))
    }
    public func write(_ data: Data) async throws {
        guard data.count <= 1_048_576 else { throw SocketError.limitExceeded }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    guard !self.closed else { continuation.resume(throwing: SocketError.closed); return }
                    guard self.writeContinuation == nil else { continuation.resume(throwing: SocketError.concurrentOperation); return }
                    self.output = data; self.offset = 0; self.writeContinuation = continuation; self.tryWrite()
                }
            }
        } onCancel: { self.close() }
    }
    private func finishWrite(_ error: (any Error)? = nil) {
        if writing { writeSource.suspend(); writing = false }
        let continuation = writeContinuation; writeContinuation = nil; output = Data()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
    private func tryWrite() {
        guard !closed, writeContinuation != nil else { return }
        var budget = 262144
        while offset < output.count {
            let count = output.withUnsafeBytes { pulse_send(fd, $0.baseAddress!.advanced(by: offset), min($0.count - offset, 65536)) }
            if count > 0 {
                offset += count; budget -= count
                if budget <= 0 { queue.async { self.tryWrite() }; return }
                continue
            }
            let error = pulse_errno()
            if count < 0 && pulse_interrupted(error) != 0 { continue }
            if count < 0 && pulse_would_block(error) != 0 {
                if !writing { writing = true; writeSource.resume() }; return
            }
            finishWrite(count == 0 ? SocketError.closed : SocketError.system(error)); return
        }
        finishWrite()
    }
}
