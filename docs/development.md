# Development

Build on macOS 26 or later. `macos/build-app.sh` produces `macos/build/Harflow.app` without installing, launching, or registering it.

Use SwiftFormat 0.62.1 and SwiftLint 0.65.0:

```sh
swiftformat macos
swiftlint lint
python3 scripts/check-legacy-names.py
python3 -m pytest tests/test_swift_package_runner.py tests/test_monitor_profile.py tests/ci
macos/build-app.sh
```

Run Swift Testing through `scripts/test-swift-package.py`, which validates supported Testing Library 1902/schema 6.3 output and fails closed. MainWindowFeature uses `--mode suites` with `HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1`; the other eight packages use `--mode aggregate` with `HARFLOW_NATIVE_BENCHMARK=1`. Do not run all package tests concurrently.

Packages live in `macos/HfFoundation`, `macos/HfCore`, `macos/HfFeatures`, and `macos/Harflow`. Public dependency versions remain SwiftEnvironment 4.1.8, Mockable 0.6.2, and Dummyable 1.1.6. JSON protocol versions remain unchanged pending protocol integration.

Never launch development builds against real user state. Use an isolated generated fixture and temporary HOME. Production Module wiring deliberately uses unavailable managed tooling and a disabled installer.
