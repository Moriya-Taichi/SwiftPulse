# Performance measurements

These are **before/after measurements of SwiftPulse**, not comparisons against SwiftNIO, Vegeta or other frameworks. The tests ran on 2026-09-07 in a shared Ubuntu 24.04 x86_64 execution environment, using Swift 6.0.3 release builds and Python 3.12. CPU affinity, frequency and other tenants were not controlled. Do not extrapolate these short localhost runs to production capacity.

Baseline: `f22e49c3773c21f05e421152894acbb89aad30b5`. The updated implementation is the package separation, incremental decoder, reusable receive buffer, multi-buffer response writer and trace ring in this change.

## HTTP results

Each scenario used five paired repetitions, alternating before/after order. The figures below are medians, not the best run. Python generated traffic independently of either Swift package. It reused connections, verified HTTP 200 and checked every echoed body. The network benchmark is closed-loop and measures throughput under a fixed number of clients; it is not a constant-rate SLO test.

| Scenario | Requests / trial | Before req/s | After req/s | Before p99 | After p99 |
|---|---:|---:|---:|---:|---:|
| Small response, trace disabled (extended) | 12,800 / 16 clients | 23,987 | 23,682 | 1.383 ms | 1.437 ms |
| Small response, tracing enabled (extended) | 12,800 / 16 clients | 21,610 | 23,004 | 1.631 ms | 1.554 ms |
| 512 KiB echo, trace disabled (short) | 160 / 4 clients | 842 | 1,430 | 11.695 ms | 5.397 ms |

The large-body short test improved throughput by about **70%**. The extended traced small-response test improved throughput by about **6.4%**. Small untraced responses did **not** show a consistent improvement: the extended median was about 1.3% lower, with slightly higher p99. Avoid describing all requests as faster.

The initial short small-response trials showed different magnitudes (including a slightly worse traced p99), illustrating sensitivity to the environment and short windows. Both sets of raw measurements are retained; the larger completed small-response set is reported above.

## CPU and memory

The extended small-response trials additionally measured each server process's CPU time and peak resident memory using `wait4`. Values include startup, 120 warm-up requests and shutdown. They exclude the Python generator. Both versions use the same 500,000-event capacity; these runs do not fill either trace buffer and do not poll Studio.

| Scenario | CPU seconds before → after | Peak RSS before → after |
|---|---:|---:|
| Small response, trace disabled | 3.109 → 3.029 | 49.00 → 46.91 MiB |
| Small response, tracing enabled | 3.355 → 3.078 | 89.14 → 76.85 MiB |

Tracing-enabled peak RSS fell by about **13.8%** in these trials. These figures combine code-path changes and the executable/package separation; they do not isolate the contribution of each change. The reusable receive buffer retains 16 KiB per normally used socket, so idle-connection memory must be measured separately before choosing large connection limits.

Attempts to extend the large-body scenario to 800 requests encountered baseline process crashes. One captured crash used signal 4 and referenced `/proc/77/stat`; the environment also prevented a full thread backtrace. This resembles the process-introspection limitation encountered with the local Swift driver, but the exact cause was not established. **The extended large-body comparison is incomplete and has no aggregate result.** Its completed trials and failure note are preserved in the extended artifact. The 70% figure comes only from the earlier complete five-pair short test.

## Decoder microbenchmark

A separate benchmark fed a 1 MiB Body in 1 KiB fragments, with 16 additional headers, 100 times per repetition. It verified all decoded lengths. Across five alternating pairs, median total time changed from **9,996.3 ms to 65.7 ms** (about 152× for this deliberately fragmented input).

The old implementation parsed the header on each fragment. The incremental decoder caches the head and waits for the remaining Body bytes. This microbenchmark isolates that repeated work; it does **not** mean the HTTP server is 152× faster.

## Reproduce

Build the baseline in a separate checkout, then the current server:

```sh
git worktree add ../SwiftPulse-before f22e49c3773c21f05e421152894acbb89aad30b5
swift build --package-path ../SwiftPulse-before -c release
swift build -c release
python3 scripts/benchmark.py \
  --before ../SwiftPulse-before/.build/release/pulse \
  --after .build/release/pulse --repeats 5 --output comparison.json

# Extended configuration used for CPU/RSS and small-response measurements
python3 scripts/benchmark.py \
  --before ../SwiftPulse-before/.build/release/pulse \
  --after .build/release/pulse --repeats 5 \
  --requests-per-connection 800 --echo-requests-per-connection 200 \
  --trace-capacity 500000 --output extended-comparison.json

# The benchmark package is optional; normal server builds do not include it.
cp -R Benchmarks ../SwiftPulse-before/Benchmarks
swift run --package-path ../SwiftPulse-before/Benchmarks -c release \
  -Xswiftc -DBASELINE pulse-microbench 100
swift run --package-path Benchmarks -c release pulse-microbench 100
```

Copy only the benchmark manifest and Sources when the directory already contains a build cache. The baseline's conditional compilation path uses the old stateless parser; the updated path uses HTTPDecoder. The local Swift toolchain required `SWIFT_USE_OLD_DRIVER=1`; normal CI builds use the standard driver.

Raw results:

- [Complete short HTTP trials](benchmarks/local-comparison.json)
- [Extended HTTP / CPU / RSS trials and incomplete large-body attempt](benchmarks/extended-comparison.json)
- [Decoder trials](benchmarks/decoder-comparison.json)
