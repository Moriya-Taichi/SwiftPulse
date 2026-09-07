# Design

SwiftPulse contains `PulseCore`, the `pulse` server/observer executable and Studio's static browser assets. `Packages/PulseLoad` is a separate Swift package with no dependency in either direction. It can be moved to its own repository without modifying its manifest or sources.

## Execution and I/O

BSD sockets are nonblocking. Dispatch read/write sources notify a per-socket serial queue after EAGAIN; a cooperative Swift thread never waits for socket readiness. A socket permits one pending read/accept and one pending write. Cancellation closes the connection and resumes pending continuations. Its descriptor closes only after both Dispatch sources acknowledge cancellation.

Receive storage is allocated lazily, grows only as required by a read, and is reused until the socket is destroyed. The default read is 16 KiB. Only initialized bytes returned by `recv` are copied into `Data`. This removes allocation and zero-filling on unsuccessful readiness probes, in exchange for retaining up to the largest read buffer on an open socket (maximum 1 MiB through the low-level API).

Small HTTP responses coalesce their header and body. Larger responses up to 64 MiB retain the existing header/body buffers through one asynchronous write operation. The queue advances through them without allocating a new `Data` or resuming a task for every chunk. The send loop still checks readiness, handles short writes and yields after a 256 KiB budget. It sends at most 64 KiB per syscall. Responses above this bound use the existing chunked *internal write loop*; this is not HTTP chunked transfer encoding.

HTTPDecoder retains a header scan offset and parsed head while waiting for the body. Each header byte is examined a bounded number of times, and the header is parsed once. Consumed pipeline input advances an offset; compaction occurs between requests at 64 KiB. Header size (16 KiB), body size (1 MiB), Host, Content-Length and ambiguous framing checks remain enforced.

Each connection has at most one handler in flight; responses preserve request order. The connection limit and read/handler/write deadlines are retained. Handler cancellation is cooperative: a handler that ignores cancellation can delay shutdown. A request ID is stable for the lifetime of its `HTTPRequest` value.

## Managed executors

`RequestExecutor` is request-scoped, with a fixed pool of serial DispatchQueue lanes. Each enqueued Swift job is assigned round-robin. A suspended job releases its lane; other work may proceed. Swift Concurrency continues to implement Tasks and actor isolation.

Executor slices record the interval around `UnownedJob.runSynchronously`, queue delay and OS thread ID. These are wall-time intervals, including OS preemption. They are not CPU utilization samples. Custom actor executors and unrelated runtime work are outside this recorder's scope. Task executor preferences propagate into structured child tasks, while actor isolation remains in effect.

## Continuous observation

TraceRecorder uses a bounded ring. A full ring overwrites its oldest span instead of stopping recording. Every span receives an increasing sequence number; one recorder has one session ID and monotonic clock origin. Total overwritten spans are reported as `droppedEvents`.

- `snapshot(after:limit:)` returns an exclusive cursor window, choosing the most recent events if a consumer has fallen behind.
- Snapshot selection copies the requested spans under the lock. JSON formatting occurs after releasing the lock. A reader never shares the mutable ring's backing array, avoiding whole-ring copy-on-write on the next append.
- Executor queue delays and thread IDs are stored as numeric values. Dictionary/string conversion happens at export time.
- Disabled tracing does not evaluate metadata autoclosures.
- `TraceEndpoint.response` caps each HTTP response at 5,000 spans. `/__pulse/trace?after=N&session=ID` requests a delta. A changed session resets the cursor domain.
- The observer route is excluded from its own handler/request/executor spans. Low-level socket reads remain framework I/O events; they are not included in request or worker metrics.

Studio reads from a fixed target origin supplied on the command line, without accepting arbitrary fetch destinations from the browser. The proxy does not follow redirects, limits the body to 16 MiB and coalesces concurrent requests for the same cursor. Browser polling is once per second, with a 20,000-event retention bound. It reports cursor gaps instead of silently presenting missing events as a complete trace.

The UI derives completed request intervals, p95 wall time, managed-job queue p95 and interval overlap from the retained events. Statistics are scoped to this window, exclude unfinished requests and may be incomplete if older related spans were overwritten. They are not lifetime counters. Request/worker correlation does not require a load-test run ID.

## Independent load testing

PulseLoad provides its own manifest, signal shim, models, URLSession client, scheduler, CLI and tests. It does not import PulseCore or access source files outside its directory. A Python HTTP server is used for integration verification; CI copies the package outside the repository before building it.

`pulse-load attack`, `report` and `compare` own load generation and result management. The server and Studio expose no load-generation routes. A client may correlate its `X-Pulse-Request-ID` values with a separately captured server trace. JSON report field meanings remain unchanged, with new reports identified as `pulseload.run`.

## Primary references

- [Swift SE-0417: Task executor preference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md)
- [Swift corelibs libdispatch](https://github.com/swiftlang/swift-corelibs-libdispatch)
- [RFC 9112: HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112)

These mechanisms do not establish a performance advantage over SwiftNIO or other frameworks. Reproducible before/after results are in [performance.md](performance.md).
