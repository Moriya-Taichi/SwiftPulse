# Validation

Verified on 2026-09-07 using Swift 6.0.3, Ubuntu 24.04 x86_64, and Node 24.19.0.

| Check | Result |
|---|---|
| Swift debug build and test | 12 tests passed, including seven malformed-header cases in a parameterized test |
| Swift release build | Passed |
| Studio data model tests | 5 passed |
| CLI/server/Studio API integration | Passed |
| Browser interaction | Passed in Linux CI, including desktop/mobile layouts and actual UI-triggered requests |
| macOS | Build, Swift tests and CLI/server/Studio API integration passed in CI |

[GitHub Actions run 34122344887](https://github.com/Moriya-Taichi/SwiftPulse/actions/runs/34122344887) passed both Linux and macOS jobs for implementation commit `2ba1137db0dd3e063d697f7a6e48e477ab86fe7e`. The local cloud browser could not connect to workspace loopback, so browser interactions were verified in CI.

The compiler's standalone driver was incompatible with this execution environment's process introspection. The local Swift build used the official `SWIFT_USE_OLD_DRIVER=1` fallback; the Swift language mode remained 6. CI uses the ordinary `swift build` and `swift test` commands.

## Integration observations

- 30 planned requests at 30 requests/sec: 30 completed, zero failures, zero dropped slots.
- The report contained 505 managed executor slices across four logical worker lanes.
- At 100 planned requests/sec for 0.5 sec, with a concurrency limit of one and a 150 ms asynchronous endpoint delay: 50 planned slots, four completed requests, 46 capacity drops.
- SIGINT produced a parseable partial report with `cancelled = true`.
- Ambiguous Content-Length input closed the connection without invoking the handler.
- Studio listed saved reports and completed an API-launched load test.

`Studio/demo-run.json` contains actual output from this localhost integration test. It is provided to demonstrate the result format and UI, **not as a performance benchmark**. The generator and target shared a constrained execution environment. These results do not establish an advantage over SwiftNIO, Hummingbird or Vegeta.

## Reproduce

```sh
swift test
node --test Tests/StudioTests/*.test.mjs
swift build -c release
python3 scripts/integration.py --binary .build/release/pulse

# Optional browser checks; development-only dependencies
npm install --no-save --package-lock=false playwright@1.55.0
npx playwright install chromium
python3 scripts/browser_integration.py --binary .build/release/pulse
```

The browser test checks sample loading, filtering, timeline mode and zoom, a real UI-triggered run, cancellation, page errors, and desktop/mobile layouts. The CI workflow uploads screenshots as `studio-browser-results`.
