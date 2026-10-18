# Development

Build on macOS 26 or later. `macos/build-app.sh` produces `macos/build/Harflow.app` without installing, launching, or registering it.

Validate formatting and lint with the same commands as CI. CI installs the available Homebrew tools; local tools are not pinned by this repository:

```sh
swiftformat --lint macos
swiftlint lint --strict
python3 scripts/check-legacy-names.py
python3 -m pytest tests/test_swift_package_runner.py tests/test_monitor_profile.py tests/ci
macos/build-app.sh
```

To apply formatting, run `swiftformat macos` separately.

Run Swift Testing through `scripts/test-swift-package.py`, which validates supported Testing Library 1902/schema 6.3 output and fails closed. MainWindowFeature uses `--mode suites` with `HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1`; the other eight packages use `--mode aggregate` with `HARFLOW_NATIVE_BENCHMARK=1`. Do not run all package tests concurrently.

Packages live in `macos/HfFoundation`, `macos/HfCore`, `macos/HfFeatures`, and `macos/Harflow`. Public dependency versions remain SwiftEnvironment 4.1.8, Mockable 0.6.2, and Dummyable 1.1.6. Ctl/setup/normalized event wire envelopes use explicit Harflow v1 contracts; persisted task/workflow storage migration is separate.

Never launch development builds against real user state. Use an isolated generated fixture and temporary HOME. Production Module wiring deliberately uses unavailable managed tooling and a disabled installer.
