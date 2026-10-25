# Development

Build on macOS 26 or later. `macos/build-app.sh` produces `macos/build/Harflow.app` without installing, launching, or registering it.

Use [the terminology guide](terminology.md) for user-facing copy and compatibility mappings.

Validate formatting and lint with the same commands as CI. CI installs the available Homebrew tools; local tools are not pinned by this repository:

```sh
swiftformat macos scripts/support --lint
swiftlint lint --strict
python3 scripts/check-legacy-names.py
python3 -m pytest tests/test_swift_package_runner.py tests/test_monitor_profile.py tests/ci
macos/build-app.sh
```

To apply formatting, run `swiftformat macos scripts/support` separately.

Run Swift Testing through `scripts/test-swift-package.py`, which validates supported Testing Library 1902/schema 6.3 output and fails closed. MainWindowFeature uses `--mode suites` with `HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1`; the other eight packages use `--mode aggregate` with `HARFLOW_NATIVE_BENCHMARK=1`. Do not run all package tests concurrently.

Packages live in `macos/HfFoundation`, `macos/HfCore`, `macos/HfFeatures`, and `macos/Harflow`. Public dependency versions remain SwiftEnvironment 4.1.8, Mockable 0.6.2, and Dummyable 1.1.6. Ctl/setup/normalized event wire envelopes use explicit Harflow v1 contracts; persisted task/workflow storage migration is separate.

Never launch development builds against real user state. Use an isolated generated fixture and temporary HOME. Pre-seed that HOME through the production ManagedRuntimeInstaller with constructor-injected local acquisitions, then launch the ordinary app against the qualified managed generation. A bare fake harflow-ctl cannot satisfy completion receipt, native import, pip, and version-info qualification. See [managed runtime](managed-runtime.md) for pinned input maintenance. No environment variable or preference overrides production acquisition endpoints.

## Swift Testing runner

`scripts/test-swift-package.py` builds once, discovers target-qualified function IDs with
`swift test list --skip-build`, and rejects empty, duplicate or unrecognized discovery.
`--mode suites` runs each suite once in a fresh serialized process with anchored filters validated
to cover discovery exactly and disjointly; `--mode aggregate` uses one guarded process.
MainWindowFeature uses suite isolation as an AppKit fixture policy. The cause of premature aggregate
exit remains unresolved, and suite isolation does not validate shared-process ordering or state
leakage. An incomplete isolated suite still fails.

The exact `MainWindowFeatureTests.ActivityFeedApprovalHostedTests` suite runs in a temporary,
ad-hoc signed AppKit application with a synchronous main function and a retained application
delegate. Its main thread runs `NSApplication.run()` throughout testing. Before loading the actual
built test bundle, a separate bare application activation check must become active with a key
fixture window. The host loads the original test bundle locally and invokes the selected toolchain's
Testing entrypoint with the original anchored suite filter; it never invokes the bundle entrypoint.
The runner rejects aggregate selections containing these tests and requires `--mode suites`.

The host uses the `xcrun` selected compiler and Testing.framework (Library 1902), checks that exactly
that Testing image remains loaded, and uses an isolated HOME, CFFIXED_USER_HOME and TMPDIR with
saved-state restoration disabled. Setup, signing and activation share the build budget. A real
legacy-only SwiftPM probe and the host share one partition deadline. The probe must exit zero with
at least one genuine XCTest report, all reporting zero tests/failures. The host's real completion
summary is validated from stderr separately from the probe's stdout; both original logs and host
setup/toolchain evidence remain in the manifest. Missing tools, bundle, registration, activation,
unsupported inputs or incomplete evidence fail without an ordinary-runner fallback.

Each partition must exit zero, define and execute every discovered function exactly once in a
complete event stream (schema 6.3.0, Testing Library 1902), and print a passing summary with the
exact logical count. Parameterized cases do not inflate that count. Recorded issues, failed
suites/tests, skips, malformed or truncated evidence, and unsupported toolchains fail validation;
legacy XCTest must report zero tests and failures. Exit code alone never establishes success.
Build/discovery time out after 600 seconds, suites after 300, and aggregate runs after 1200.
Timeout cleanup signals only the runner-owned process group: TERM, five seconds of grace, then
KILL including surviving descendants. Surviving descendants after normal exit fail the run;
interruptions also clean up the owned group. The runner supports Python 3.9+. Flushed partition
progress identifies the log directory; full logs, event streams and a final manifest retain
evidence. Remaining independent partitions run after failures, then the runner exits nonzero.
Fake-Swift regression tests live in `tests/test_swift_package_runner.py`.

## Continuous integration

`.github/workflows/macos.yml` runs both guards, the Python runner and CI tests, SwiftFormat `--lint`
and SwiftLint `--strict`, `macos/build-app.sh`, a packaged-startup bundle check, and the guarded
Swift package tests. `release.yml` and `apple-signing-preflight.yml` cover releases and credential
preflight; see `docs/releasing.md` and `docs/ci-signing.md`. Signed runs upload the app to Apple and,
like pushes and releases, need explicit owner authorization in the active task.
