# HfRepository

The repository layer exposes constructor-injected, nonisolated Sendable business contracts over MonitorCore. See [architecture rules](../../AGENTS.md).

Production Module wiring uses `ManagedToolEnvironmentRepository` and `ManagedInstallRepository`: runtime operations remain explicitly unavailable. This wiring does not discover executables, probe compatibility, install software, or read user task state.

For an explicitly selected runtime, ctl/setup clients carry the selected absolute state-root context and probe compatibility for every operation. Event activity, summary readers, and task-store watchers await an injected `StoreCompatibilityCheck` before I/O, matching the selected tasks directory's parent. Released leases and obsolete generations cannot start delayed reads or watchers. Compatibility failures are explicit unavailable/error states. The gate checks contracts and release lines; storage ownership and verified runtime activation are separate work.

## What is here

| Type | Owns |
|---|---|
| `Scheduling` / `SystemScheduler` | The one scheduling seam every production timer in this package uses (1 s throttle, 10 s poll) — injectable so tests never sleep. |
| `SettingsRepository` | `UserDefaults`-backed `toolDirectory` / `openWindowOnStart` / `notifyOnFinish`, published live. |
| `ToolEnvironmentRepository` | Selected tooling and launch environment; production managed tooling remains unavailable. |
| `TaskArtifactRepository` | Explicit bounded pages of registered standalone-task artifact metadata; unavailable reads remain distinct from an empty manifest. |
| `TaskSnapshotRepository` | Per-task `harflow-ctl status` snapshots. |
| `EventStreamRepository` | Ref-counted per-task event tailing, shared across every screen watching the same task; also publishes each task's `EventAvailability` (`loading`/`available`/`unavailable`), so a caller never has to infer "the log couldn't be read" from an empty event list. |
| `TaskListRepository` | `harflow-ctl list`, refresh coalescing, titles, the FSEvents throttle, the safety poll, `detail()` precedence. |
| `FinishNotifier` | User notifications for roots that finished since the last listing. |
| `TaskActionRepository` | Busy set + outcome line (durable, keyed by task id), cancel/send/resume/run, the raw takeover-grant passthrough. |
| `TakeoverService` | Opens a task's session in Terminal.app — `ctl takeover` grant → hand-off files → `open -a Terminal`; the only take-over destination the Monitor offers. |
| `HarnessRepository` | `harflow-setup` status/install/remove. |
| `InstallRepository` | Production managed installation is disabled. Retained installer implementations are isolated test seams. |
| `DirectoryWatcher` | FSEvents on the tasks folder, moved here in Swift 6 mode with a `@Sendable` handler. |

Every protocol is `@Mockable`; every `@GlobalEntry` default is a hand-written `Null*` struct (see
`AGENTS.md` for why, not the `@Dummyable` macro). `Module: HfModule` wires concrete instances once,
in dependency order, in `initializeModule()`.

## Build and test

```bash
cd macos/HfCore/HfRepository
swift build
HARFLOW_NATIVE_BENCHMARK=1 python3 ../../../scripts/test-swift-package.py --package . --mode aggregate
```

`AppModulesRegistry` registers `HfRepository.Module`; screens access repositories through their own `ViewRepository` contracts.
