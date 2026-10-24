# HfRepository

The repository layer exposes constructor-injected, nonisolated Sendable business contracts over MonitorCore. See [architecture rules](../../AGENTS.md).

Production Module constructs one `ManagedRuntimeCoordinator` and injects it into `ManagedToolEnvironmentRepository` and `ManagedInstallRepository`. Concurrent startup consumers join the same acquisition attempt, including failure. The coordinator retains failure until explicit retry; synchronous ctl/setup access reports distinct preparation/failure refusal codes until a generation is qualified. Only the install adapter restarts the task-list watcher when an explicit post-failure retry succeeds. Initial readiness never triggers that restart.

For an explicitly selected runtime, ctl/setup clients carry the selected absolute state-root context and probe compatibility for every operation. Event activity, summary readers, and task-store watchers await an injected `StoreCompatibilityCheck` before I/O, matching the selected tasks directory's parent. Released leases and obsolete generations cannot start delayed reads or watchers. Compatibility failures are explicit unavailable/error states. The gate checks contracts and release lines; managed completion receipts and qualification independently gate runtime activation.

## What is here

| Type | Owns |
|---|---|
| `Scheduling` / `SystemScheduler` | The one scheduling seam every production timer in this package uses (1 s throttle, 10 s poll) — injectable so tests never sleep. |
| `AgentUsageRepository` | Shared lifetime counts for acknowledged app submissions, persisted atomically with processed task/run IDs and published as equality-deduplicated snapshots. |
| `SettingsRepository` | `UserDefaults`-backed `toolDirectory` / `openWindowOnStart` / `notifyOnFinish` / app-wide appearance, published live. |
| `ToolEnvironmentRepository` | Selected tooling and launch environment; managed app clients bind the exact qualified generation. |
| `TaskArtifactRepository` | Explicit bounded pages of registered standalone-task artifact metadata; unavailable reads remain distinct from an empty manifest. |
| `TaskSnapshotRepository` | Per-task `harflow-ctl status` snapshots. |
| `EventStreamRepository` | Ref-counted per-task event tailing, shared across every screen watching the same task; also publishes each task's `EventAvailability` (`loading`/`available`/`unavailable`), so a caller never has to infer "the log couldn't be read" from an empty event list. |
| `TaskListRepository` | `harflow-ctl list`, refresh coalescing, titles, the FSEvents throttle, the safety poll, `detail()` precedence. |
| `FinishNotifier` | User notifications for roots that finished since the last listing. |
| `TaskActionRepository` | Busy set + outcome line (durable, keyed by task id), cancel/send/resume/run, the raw takeover-grant passthrough. |
| `TakeoverService` | Opens a task's session in Terminal.app — `ctl takeover` grant → hand-off files → `open -a Terminal`; the only take-over destination the Monitor offers. |
| `HarnessRepository` | `harflow-setup` status/install/remove. |
| `InstallRepository` | Shared managed preparation/status/retry; row setup actions remain explicit MCP registration. |
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
