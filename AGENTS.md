# HarflowMac

Native macOS application for Harflow: the task and workflow monitor, managed engine acquisition and
lifecycle, platform integration, signing, and application releases. The engine (MCP server,
`harflow-ctl`, `harflow-setup`, state persistence) lives in the separate `HarflowMCP` repository;
interface designs belong in `HarflowDesign`
(https://github.com/Harflow-Dev/HarflowDesign), edited directly in Git and previewed
in a browser. Do not use OpenDesign or create a separate managed design copy.
The publication target is https://design.harflow.dev; verify its deployed revision
before using it as an implementation reference.
Refine interface changes there first and reference the approved design commit,
file path, and screen state during implementation. Each feature issue's "Design reference" section
names that commit and its states; read the design from a local `../HarflowDesign` checkout or
https://design.harflow.dev rather than copying it into this repository. Never make a build, test or
release here depend on a sibling checkout.

## Documentation

- Keep `README.md` focused on the product: purpose, current capabilities and limitations,
  prerequisites, getting started, and links to maintained guides.
- Put version history, release notes, fixes, migration milestones, and other change records in
  `CHANGELOG.md`. Do not use the README as a changelog or implementation-progress log. Link to
  `CHANGELOG.md` from the README.
- Keep detailed current behavior and technical guidance in `docs/`: `development.md`,
  `architecture.md`, `managed-runtime.md`, `monitor-performance.md`, `releasing.md` and
  `ci-signing.md`.

When a change affects user-facing behavior, setup, supported capabilities or recovery, update the
README and the relevant guide in the same change.

## Commands

```bash
swiftformat macos && swiftlint lint --strict   # format, then lint; CI pins swiftformat 0.60.1 and swiftlint 0.63.2 (SHA-256-verified release downloads, no brew) and runs `swiftformat macos scripts/support --lint`
python3 scripts/check-legacy-names.py          # legacy product-name guard
scripts/check-private-refs.sh                  # private-reference guard
python3 -m pytest tests/test_swift_package_runner.py tests/test_monitor_profile.py tests/ci
macos/build-app.sh                             # build macos/build/Harflow.app (build only)
HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1 python3 scripts/test-swift-package.py --package macos/HfFeatures/MainWindowFeature --mode suites
for p in macos/HfFoundation/* macos/HfCore/* macos/HfFeatures/MenuBarFeature macos/HfFeatures/SettingsFeature macos/Harflow; do HARFLOW_NATIVE_BENCHMARK=1 python3 scripts/test-swift-package.py --package "$p" --mode aggregate || exit 1; done
```

Build on macOS 26 or later. Run package tests one at a time, never concurrently, and only through
`scripts/test-swift-package.py`; exit code alone never establishes success, because the runner
validates the Swift Testing event stream and fails closed (see the "Swift Testing runner" section
of `docs/development.md`). Before finishing any change under `macos/`, run the format, lint and
both guards. Repository-root `.swiftformat` and `.swiftlint.yml` apply; MonitorCore's existing
source violations live in `.swiftlint-baseline.json`, so never edit
`macos/HfCore/MonitorCore/Sources` just to satisfy a rule.

**Never launch development builds against real user state.** Use an isolated generated fixture and
a temporary HOME pre-seeded through the production `ManagedRuntimeInstaller`, as described in
`docs/development.md`. App tests never invoke real engine binaries.

## Repository guards

- `scripts/check-private-refs.sh` keeps this open-source tree from naming a private project. Its
  patterns are assembled from pieces inside the script; never quote them elsewhere, and never write
  absolute paths under a personal home directory into tracked files.
- `scripts/check-legacy-names.py` rejects the pre-extraction product name, its environment prefix
  and its two-letter module prefix (any word starting with that prefix, in either case) in every
  tracked or addable file and path. Packages use the `Hf` prefix. Required surviving literals are
  listed with exact counts and reasons in `scripts/legacy-name-allowlist.json`; do not add an
  exception to avoid a rename.

## Architecture

The app is a set of SwiftPM packages wired by path: `macos/HfFoundation/`, `macos/HfCore/`,
`macos/HfFeatures/` and `macos/Harflow/` (app shell only). `macos/AGENTS.md` is the shared
architecture rulebook, including background computation, main-actor application and rendering
publisher equality; each package's own `AGENTS.md` says what that package owns.
`docs/architecture.md` describes runtime composition.

## The app consumes engine contracts

The engine repository owns the public wire contracts (`harflow.ctl`, `harflow.setup`,
`harflow.event`, `harflow.version-info`, each wire `v: 1`) and their specification and canonical
fixtures. This app must vendor byte-identical copies of the engine's `contracts/v1` in
`macos/HfCore/MonitorCore/Tests/MonitorCoreTests/Resources/ContractsV1`, including `manifest.json`
and a matching `manifest.sha256`, and builds without fetching them. When the engine bundle changes,
re-vendor the whole bundle and compare the two `manifest.sha256` files; do not assume they are in
sync.

- The app acts only through `harflow-ctl` and `harflow-setup` from the selected managed runtime. It
  never writes a task record, phase file or inbox itself, and every fact it shows comes from the
  engine; backend names appear only for display styling.
- Each contract is gated independently on the Swift side: `ctlContractVersions` in
  `MonitorCore/CtlModels.swift`, `setupContractVersion` in `SetupClient.swift`, and
  `eventLogVersion` in `Events.swift`. The app refuses any version outside the set it understands,
  naming the tool and the versions understood, rather than guessing.
- Ctl/setup commands and asynchronous store readers validate the selected runtime and lexical state
  root before each operation (see `macos/HfCore/MonitorCore/README.md`).
- A new event kind means `TaskEvent.Kind` in `macos/HfCore/MonitorCore/Sources/MonitorCore/Events.swift`
  and the engine's `events.EVENT_KINDS` together; an unknown kind decodes as `.unknown` and is
  ignored, so an older app degrades quietly. When the app invokes a ctl command an older engine
  lacks, the engine's usage error maps to `ToolError.unsupportedCommand`, and the caller falls back
  (for example `statusBatch` falls back to per-id `status`).
- Any other shape change is a cross-repository contract change: agree it in the engine first,
  then update the vendored fixtures, decoders and version gates here.

## Managed runtime and releases

The app never embeds an engine or interpreter. MonitorCore owns acquisition, installation locking,
hash verification, qualification and immutable generations; see `docs/managed-runtime.md` and
`docs/releasing.md`. CI is described in `docs/development.md`, `docs/releasing.md` and
`docs/ci-signing.md`. Signed runs upload the app to Apple and, like pushes and releases, need
explicit owner authorization in the active task.
