# HfRepository

The repository layer for the Harflow: everything `AppModel` used to do by directly
calling `MonitorCore`, now split into small, independently-testable, `nonisolated` `Sendable`
repositories. See `../../CLAUDE.md` (the root architecture rulebook) and
`../../.claude/plans/2026-09-25-monitor-architecture-plan-settled.md` (Phase 3) for the full
context this package implements.

## What is here

| Type | Owns |
|---|---|
| `Scheduling` / `SystemScheduler` | The one scheduling seam every production timer in this package uses (1 s throttle, 10 s poll) — injectable so tests never sleep. |
| `SettingsRepository` | `UserDefaults`-backed `toolDirectory` / `openWindowOnStart` / `notifyOnFinish`, published live. |
| `ToolEnvironmentRepository` | Login-PATH + `uv` discovery, `ctl()`/`setup()` client construction, the launch environment. |
| `TaskArtifactRepository` | Explicit bounded pages of registered standalone-task artifact metadata; unavailable reads remain distinct from an empty manifest. |
| `TaskSnapshotRepository` | Per-task `harflow-ctl status` snapshots. |
| `EventStreamRepository` | Ref-counted per-task event tailing, shared across every screen watching the same task; also publishes each task's `EventAvailability` (`loading`/`available`/`unavailable`), so a caller never has to infer "the log couldn't be read" from an empty event list. |
| `TaskListRepository` | `harflow-ctl list`, refresh coalescing, titles, the FSEvents throttle, the safety poll, `detail()` precedence. |
| `FinishNotifier` | User notifications for roots that finished since the last listing. |
| `TaskActionRepository` | Busy set + outcome line (durable, keyed by task id), cancel/send/resume/run, the raw takeover-grant passthrough. |
| `TakeoverService` | Opens a task's session in Terminal.app — `ctl takeover` grant → hand-off files → `open -a Terminal`; the only take-over destination the Monitor offers. |
| `HarnessRepository` | `harflow-setup` status/install/remove. |
| `InstallRepository` | The guarded "Install harflow" pipeline (git → uv → harflow → validate) and its state machine — see `Install/InstallCommands.swift`/`Install/InstallRepositoryImpl.swift`. |
| `DirectoryWatcher` | FSEvents on the tasks folder, moved here in Swift 6 mode with a `@Sendable` handler. |

Every protocol is `@Mockable`; every `@GlobalEntry` default is a hand-written `Null*` struct (see
`AGENTS.md` for why, not the `@Dummyable` macro). `Module: HfModule` wires concrete instances once,
in dependency order, in `initializeModule()`.

## Build and test

```bash
cd macos/HfCore/HfRepository
swift build
swift test
```

This package has been linked into the app target since Phase 3 (`HfRepository.Module` is
registered by `AppModulesRegistry`, alongside every other module) — there is no `AppModel` any more;
every screen reads these repositories through its own `ViewRepository`.
