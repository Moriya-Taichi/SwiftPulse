# Design

SwiftPulse consists of `PulseCore`, `PulseLoad`, the `pulse` executable and a dependency-free browser UI. Swift's concurrency runtime remains responsible for Tasks and actor isolation; this project does not implement a replacement Swift runtime.

## Transport and ownership

The C layer is a small portable wrapper around BSD socket functions, with nonblocking and close-on-exec flags. Linux sends use `MSG_NOSIGNAL`; Darwin sockets use `SO_NOSIGPIPE`. DispatchSource supplies OS readiness events. There is no polling loop over sockets and no thread per connection.

Each socket has a serial state queue. Read and write sources remain suspended unless an operation encounters EAGAIN. Each source cancellation handler participates in descriptor lifetime accounting, so a descriptor is not closed/reused before both sources have acknowledged cancellation. A cancelled read or write closes the entire socket and resumes all pending continuations exactly once. Concurrent reads and concurrent writes are rejected rather than silently racing.

The server caps connection count before creating a handler Task. Header and request-body buffering are bounded. Each read, handler and response write has a deadline; task cancellation propagates to the relevant socket. A handler that ignores cooperative cancellation cannot be forcibly terminated. Responses use 64 KiB writes and socket write operations are capped at 1 MiB. HTTP requests are processed in connection order.

The current transport is readiness-based. Direct epoll/kqueue or io_uring backends should only be introduced after measuring benefits against this baseline. TLS, HTTP/2 and a general streaming body abstraction are not claimed in this version.

## Managed execution

`RequestExecutor` uses the public Swift 6 `TaskExecutor` API. An instance per request retains an explicit request ID and submits jobs to a shared set of serial worker queues. This avoids guessing Task identities from thread-local state. Default actor behavior and explicitly selected actor executors retain their Swift semantics.

Workers are logical queue lanes, not CPU cores or pinned threads. Scheduling is round-robin, not work stealing. This is a deliberately small starting point whose locality, fairness, queueing cost and allocation overhead must be benchmarked before more complex scheduling is justified.

## What the trace can establish

- Managed executor job: start and return time, request ID, logical worker and actual OS thread ID. This measures a wall-time slice, potentially including OS descheduling.
- Queue wait: enqueue-to-job-start time, recorded separately in each job's arguments.
- Handler, socket read and response write: elapsed wall time across suspension/resumption, not CPU time.
- Unrelated executor jobs, external actors and kernel scheduling: not observed.

The UI never treats overlapping HTTP request spans as proof of simultaneous CPU execution. It filters imported server events by the load run's explicit request-ID prefix and does not align monotonic clocks from different hosts. Traces retain their own relative timeline. Records use Chrome Trace Event complete events (`ph: X`, microseconds).

The recorder has a fixed event capacity and a dropped-event counter. Disabled recording avoids building executor event metadata. The initial recorder uses a mutex and allocates event metadata while enabled; it is not a lock-free or zero-overhead implementation. Sampling and per-worker ring buffers are future optimizations, not existing capabilities.

## Load generation and measurement

The scheduler creates slots at `origin + sequence / rate` independently of prior responses. It reserves a bounded in-flight slot before creating a child Task. If the generator is late or at capacity, the planned slot is counted as dropped, not delayed indefinitely. The last slot is followed by the remainder of the requested issuance period, and outstanding requests then drain.

The transport uses URLSession (FoundationNetworking on Linux), not SwiftNIO. DNS, TLS, connection pooling and protocol negotiation are delegated to it. Bodies are counted and discarded by a streaming delegate, with a configurable maximum. Request status, error, scheduler lag, transport wall time and schedule-to-completion are recorded. Redirects are not followed.

Aggregates include every completed request. The fixed-size logarithmic histogram uses nearest-rank upper bucket bounds with about 2% relative quantization above 1μs. Raw records stop at the configured sample cap, so the request table is explicitly a retained subset, not an unbiased distribution. Missed slots have no fabricated latency. The result format is versioned but is not Vegeta's format.

## Performance experiments

Build in release mode. Run the generator on a separate machine when evaluating throughput. Record compiler, CPU, OS, transport configuration, endpoint work, keep-alive, rate, duration and in-flight limit. Use the same conditions for baseline/candidate comparisons and warm up before retained runs.

Measure target/start/completion rates, failures, both kinds of dropped slots, latency percentiles, scheduler lag, resident memory, allocations and context switches. Compare tracing disabled and enabled separately. Do not conclude a throughput advantage from the included localhost integration sample.

Useful workload families: small responses, many idle connections, slow receivers, asynchronous I/O delay, CPU work with fan-out, large bodies, and overload beyond the connection/in-flight limits. Correctness and bounded resource use are prerequisites to optimizing a metric.

## References

- [Swift Task Executor Preference (SE-0417)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md)
- [Vegeta's constant-rate load testing design](https://github.com/tsenart/vegeta)
- [Perfetto trace import formats](https://perfetto.dev/docs/getting-started/other-formats)
- [SwiftNIO's async API boundary](https://forums.swift.org/t/new-swiftnio-async-apis/68056)
