# Validation

Local verification on 2026-09-07: Swift 6.0.3, Ubuntu 24.04 x86_64, Node 24.19.0 and Python 3.12.

| Check | Result |
|---|---|
| SwiftPulse build / Swift tests | Passed; 11 tests, including parameterized malformed-header cases |
| PulseLoad build / Swift tests | Passed; standalone package, 2 tests |
| Studio data-model tests | Passed; 7 tests |
| Server and observer integration | Passed |
| PulseLoad against Python HTTP server | Passed |
| Linux/macOS and browser CI for this revision | Pending publication; workflow updated |

The server integration checks ordinary request correlation, trace ring overwrite, cursor deltas, server restart, a 1,004,000-byte echo, HEAD, malformed framing, a read timeout and the read-only Studio API. There is no dependency on the load package.

PulseLoad's integration suite targets a Python HTTP server. It checks normal requests, saturation accounting, response-body limits, HTTP errors, redirect non-following, POST bodies, signal cancellation, report reading and comparison. CI copies the package out of the repository before building it.

The browser suite checks live observation of an ordinary HTTP request, pausing, sample loading, JSON import/export, request correlation, search, zoom, absence of load-test controls, page errors and desktop/mobile layouts. CI uploads screenshots as `studio-browser-results`. The workspace's cloud browser cannot access its local loopback, so the browser gate runs in CI.

The local Swift standalone driver was incompatible with the environment's process introspection; local builds used the official `SWIFT_USE_OLD_DRIVER=1` fallback. CI uses ordinary Swift commands. Additional performance measurements and their limitations are documented in [performance.md](performance.md).

`Studio/demo-trace.json` is the trace extracted from the previous version's actual localhost integration output. It demonstrates trace rendering without requiring a load-test report. It is not a synthetic performance claim.

## Reproduce

```sh
swift test
node --test Tests/StudioTests/*.test.mjs
swift build -c release
python3 scripts/integration.py
swift test --package-path Packages/PulseLoad
swift build --package-path Packages/PulseLoad -c release
python3 Packages/PulseLoad/scripts/integration.py

npm install --no-save --package-lock=false playwright@1.55.0
npx playwright install chromium
python3 scripts/browser_integration.py
```
