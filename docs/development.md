# Development

Build with Xcode 26.6 on macOS 26 or later. Open `macos/Harflow.xcodeproj` directly (there is no wrapper workspace) and select the shared HarflowHost scheme. The thin HarflowHost Xcode application target owns the sole entry point, packaging and signing; the Harflow SwiftPM library retains coordination/lifecycle code and its guarded tests. `macos/build-app.sh` produces `macos/build/Harflow.app` without installing or launching it.

Use [the terminology guide](terminology.md) for user-facing copy and compatibility mappings.

Validate formatting and lint with the same versions as CI: SwiftFormat 0.60.1 and SwiftLint 0.63.2. CI verifies their release archive hashes; use those versions locally:

```sh
swiftformat macos scripts/support --lint
swiftlint lint --strict
python3 scripts/check-legacy-names.py
python3 -m pytest tests/test_swift_package_runner.py tests/test_monitor_profile.py tests/ci
macos/build-app.sh
```

The build script delegates to the Xcode project in Release by default (`CONFIGURATION=debug` selects Debug), builds arm64 and applies only a local ad-hoc signature. Both configurations disable the separate debug dylib so the bundle retains one known executable. A native Xcode build automatically registers the generated app bundle with LaunchServices; it does not install the app or perform MCP/backend registration. Building does not authorize running the ordinary app against user state. Package resolution uses committed pins with automatic updates disabled; it does not authorize dependency installation or upgrades. SwiftPM package builds are library/test builds, not a second application packaging route.

To apply formatting, run `swiftformat macos scripts/support` separately.

Run Swift Testing through `scripts/test-swift-package.py`, which validates supported Testing Library 1902/schema 6.3 output and fails closed. MainWindowFeature uses `--mode suites` with `HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1`; the other eight packages use `--mode aggregate` with `HARFLOW_NATIVE_BENCHMARK=1`. Do not run all package tests concurrently.

Packages live in `macos/HfFoundation`, `macos/HfCore`, and `macos/HfFeatures`; the app-shell package is `macos/HfFeatures/Harflow`. Public dependency versions remain SwiftEnvironment 4.1.8, Mockable 0.6.2, and Dummyable 1.1.6. Ctl/setup/normalized event wire envelopes use explicit Harflow v1 contracts; persisted task/workflow storage migration is separate.

Never launch development builds against real user state. Use an isolated generated fixture and temporary HOME. Pre-seed that HOME through the production ManagedRuntimeInstaller with constructor-injected local acquisitions, then launch the ordinary app against the qualified managed generation. A bare fake harflow-ctl cannot satisfy completion receipt, native import, pip, and version-info qualification. See [managed runtime](managed-runtime.md) for pinned input maintenance. No environment variable or preference overrides production acquisition endpoints.

Temporary HOME does not by itself establish application-preference isolation. On the S02 macOS 26.6.2 host, Foundation resolved the scratch home but did not read the preseeded scratch preferences, including notification flags. Before launching a development app, verify the effective preference domain and notification settings as well as the managed engine root. Use a separate test bundle identity without URL schemes, and do not write owner preferences without explicit authorization. See the [S02 fixture evidence](migration-receipts/S02-fixture.md).

## Swift Testing runner

`scripts/test-swift-package.py` builds once, discovers target-qualified function IDs with
`swift test list --skip-build`, and rejects empty, duplicate or unrecognized discovery.
`--mode suites` runs each suite once in a fresh serialized process with anchored filters validated
to cover discovery exactly and disjointly; `--mode aggregate` uses one guarded process.
MainWindowFeature uses suite isolation as an AppKit fixture policy. The cause of premature aggregate
exit remains unresolved, and suite isolation does not validate shared-process ordering or state
leakage. An incomplete isolated suite still fails.

The exact `MainWindowFeatureTests.ActivityFeedApprovalHostedTests` and
`MainWindowFeatureTests.ObservationHostedTests` suites each run in a separate temporary,
ad-hoc signed AppKit application process with a synchronous main function and a retained application
delegate. Its main thread runs `NSApplication.run()` throughout testing. Before loading the actual
built test bundle, a separate bare application activation check must become active with a key
fixture window. The host loads the original test bundle locally and invokes the selected toolchain's
Testing entrypoint with the original anchored suite filter; it never invokes the bundle entrypoint.
The runner admits only those two exact suite identities in MainWindowFeature with their own exact
anchored filters. Aggregate selections, mixed hosted/ordinary tests, and combinations of both hosted
suites in one partition are rejected; `--mode suites` keeps their processes isolated.
The runner stably places these two admitted suites first immediately after activation preflight,
preserving their relative order and the canonical order of ordinary partitions. This reduces the
activation-to-suite delay; it does not guarantee a shorter unlocked-desktop window. The desktop
must remain available throughout native execution.
`TaskDetailObservationHostedTests` remains ordinary geometry coverage.

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

Interaction presentation and public routes are documented in [interaction surfaces](interaction-surfaces.md). Native fixture captures are separate evidence from browser specimens.
