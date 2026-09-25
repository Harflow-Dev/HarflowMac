# PbRepository

The repository layer for the Polybridge Monitor: everything `AppModel` used to do by directly
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
| `TaskSnapshotRepository` | Per-task `polybridge-ctl status` snapshots. |
| `EventStreamRepository` | Ref-counted per-task event tailing, shared across every screen watching the same task. |
| `TaskListRepository` | `polybridge-ctl list`, refresh coalescing, titles, the FSEvents throttle, the safety poll, `detail()` precedence. |
| `FinishNotifier` | User notifications for roots that finished since the last listing. |
| `TaskActionRepository` | Busy set + outcome line (durable, keyed by task id), cancel/send/resume/run, the raw takeover grant/attach passthrough. |
| `GitChangesRepository` / `FilePreviewRepository` | Stateless wrappers over `GitInspector` and the untracked-file preview read. |
| `HarnessRepository` | `polybridge-setup` status/install/remove. |
| `DirectoryWatcher` | FSEvents on the tasks folder, moved here in Swift 6 mode with a `@Sendable` handler. |

Every protocol is `@Mockable`; every `@GlobalEntry` default is a hand-written `Null*` struct (see
`AGENTS.md` for why, not the `@Dummyable` macro). `Module: PbModule` wires concrete instances once,
in dependency order, in `initializeModule()`.

## Build and test

```bash
cd macos/PbCore/PbRepository
swift build
swift test
```

This package has been linked into the app target since Phase 3 (`PbRepository.Module` is
registered by `AppModulesRegistry`, alongside every other module) — there is no `AppModel` any more;
every screen reads these repositories through its own `ViewRepository`.
