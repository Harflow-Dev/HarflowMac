# HfRepository

The repository layer exposes constructor-injected, nonisolated Sendable business contracts over MonitorCore. See [architecture rules](../../AGENTS.md).

Production Module constructs one `ManagedRuntimeCoordinator` and injects it into `ManagedToolEnvironmentRepository` and `ManagedInstallRepository`. Concurrent startup consumers join the same reuse-only qualification attempt, including failure. Acquisition starts only from an explicit install/update/retry action. The coordinator retains failure until explicit retry; synchronous ctl/setup access reports distinct preparation/failure refusal codes until a generation is qualified. Only the install adapter restarts task-list observation when an explicit acquisition succeeds. Recovery completion uses the same narrow readiness refresh without invalidating the retained receipt. Initial readiness never triggers that restart.

For an explicitly selected runtime, ctl/setup clients carry the selected absolute state-root context and probe compatibility for every operation. Event activity and summary readers await an injected `StoreCompatibilityCheck` before I/O, matching the selected tasks directory's parent. Released leases and obsolete generations cannot start delayed reads or observations. Compatibility failures are explicit unavailable/error states. The gate checks contracts and release lines; managed completion receipts and qualification independently gate runtime activation.

## What is here

| Type | Owns |
|---|---|
| `Scheduling` / `SystemScheduler` | The one scheduling seam every production timer in this package uses (including public task-list observation) — injectable so tests never sleep. |
| `AgentUsageRepository` | Shared lifetime counts for acknowledged app submissions, persisted atomically with processed task/run IDs and published as equality-deduplicated snapshots. |
| `SettingsRepository` | `UserDefaults`-backed `toolDirectory` / `openWindowOnStart` / `notifyOnFinish` / app-wide appearance, published live. |
| `ToolEnvironmentRepository` | Selected tooling and launch environment; managed app clients bind the exact qualified generation. |
| `TaskArtifactRepository` | Explicit bounded pages of registered standalone-task artifact metadata; unavailable reads remain distinct from an empty manifest. |
| `ResourceSlotsRepository` | Visibility-leased, runtime-bound resource inventory and phase status, with bounded owner metadata, retained failed-refresh evidence and generation-safe teardown. |
| `TaskPromptRepository` | One-shot typed public prompt reads, bound to selected tooling and a required caller lifetime/generation fence; no cache or rendered consumer adoption. |
| `TaskSnapshotRepository` | Per-task `harflow-ctl status` snapshots. |
| `EventStreamRepository` | Ref-counted per-task event tailing, shared across every screen watching the same task; also publishes each task's `EventAvailability` (`loading`/`available`/`unavailable`), so a caller never has to infer "the log couldn't be read" from an empty event list. |
| `StateRecoveryRepository` | Shared structured store refusals and explicit inspection/confirmation/recovery lifecycle; single-flight operations and stale-result checks remain independent of managed acquisition. |
| `TaskListRepository` | Bounded public task-history/status reads, titles, action refresh barriers, replaceable invalidation observation and `detail()` precedence. |
| `FinishNotifier` | User notifications for roots that finished since the last listing. |
| `TaskActionRepository` | Busy set + outcome line (durable, keyed by task id), cancel/send/resume/run, the raw takeover-grant passthrough. |
| `TakeoverService` | Opens a task's session in Terminal.app — `ctl takeover` grant → hand-off files → `open -a Terminal`; the only take-over destination the Monitor offers. |
| `QualificationRepository` | Cached engine-owned feature requirements and explicit checks, with per-consumer cancellation, identity validation and runtime-bound launch tokens. |
| `HarnessRepository` | `harflow-setup` status/install/remove. |
| `InstallRepository` | Shared managed preparation/status/retry; row setup actions remain explicit MCP registration. |
| `TaskListInvalidationSource` | Timing/change signals only; the polling implementation drives public refreshes and can be replaced by a later ctl watcher at composition. |

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

`StatisticsRepository` exposes explicit public history pages. Its implementation receives tooling and state recovery through constructor injection, checks cancellation, and reports structured store refusal through the shared recovery boundary. The null repository is unavailable, not an empty history.

`NeedsYouRepository` publishes one deduplicated snapshot of every request the Monitor can answer now, plus disposable `NeedsYouEvent`s for notifications. It is started once by the app shell. `NeedsYouNotifier` posts notifications with user-info keys `needs_you_item` (an item id beginning `input:`, `attention:` or `approval:`) and `needs_you_list` (`"1"` for the grouped summary); the app routes both to the Needs you screen. Approval notifications name only the tool.

`InteractionEventNotifier` consumes the capability-gated public interaction feed for individual macOS pending, answered, completed and failed banners. It persists app-owned event deduplication per selected state root and disables the legacy Needs you and finish sources while the durable feed is supported. Missing capability retains the legacy sources. It never writes engine records.

## Task-list observation

TaskList no longer watches the engine's tasks directory. Module injects a small invalidation source; it requests refreshes while the repository retains all authoritative public reads, bounds, generation checks and action barriers. The polling source checks urgency every second: visible window/popover, running/unreconciled work, errors or preparing/incomplete catalog state request a refresh; hidden idle observations request one after30seconds of elapsed scheduler time. Actual completion depends on public command duration. Every operation retains its own fresh handshake; no compatibility cache or engine-private fallback is used.

Periodic ticks are disposable while a refresh is busy, so they cannot keep a slow refresh chain alive. Explicit refreshes and refreshAndWait retain their separate coalescing/result semantics. Runtime changes fence late callbacks/results and cancel obsolete observation; cancellation also remains effective when a scheduler retains a callback. Initial readiness failure uses the existing10second retry before observation starts. Manual pre-start preparation uses a separate2second retry through idle-only admission; production observation owns progress after start.

A future public watcher can replace the polling source without changing paging, title/notification ordering, selection or task actions. Its canonical contract, qualified runtime and conformance are separate work. EventStream activity and cumulative summaries still use the existing private transport until their later M03 suffix; this task-list change does not claim all private engine I/O is removed.

## Public prompt foundation

The prompt repository captures the selected ctl client per read, composes its
existing fence with the caller's required generation/lifetime fence, and checks
executable, effective environment and compatibility-root identity against current
local tooling. Both stale successes and stale failures are discarded before
return or recovery reporting. Each read keeps the client's fresh capability
handshake. The caller must handle selection ABA in its fence and recheck identity
before future presentation. No subscription, compatibility cache or private
prompt fallback is introduced. Missing capability and known unavailable prompt
results remain distinct. Current EventStream summaries and rendered String?
prompt paths are unchanged pending the later event-transport and approved design
work; this adapter alone does not migrate those consumers.

## Internal public-event observation

The internal `PublicEventObservationManager` shares a public-page session by exact
task identifier. It is not registered in `Module` or used by the production
`EventStreamRepository`. Existing activity and summary readers remain in place
pending the approved consumer cutover described in
`docs/migration-receipts/M03-D2B-requirements.md` at repository root.

One newest bootstrap supplies the opaque cursor lineage for activity and a
bounded oldest-seek/chronological-summary replay. Unknown, missing, truncated or
ambiguous payloads retain raw facts and qualify totals as unavailable; optional
observed totals never certify complete capture. Event display prompts are not
stored assignment authority. Prompt state remains not requested in this layer;
the separate typed task-prompt reader supplies future assignment integration.

Admission is single-flight per session and globally two operations per manager.
Each external one-second tick allows at most two forward activity pages and two
forward summary-tail pages. Historical seek/replay/recovery has a cumulative
4096-operation ceiling independent of ordinary live polling. Activity holds at
most 2,000 normalized records/4MiB serialized bytes, with whole-page refusal at
capacity and no cursor advance or silent eviction. Summary keys and unresolved
call identities have separate count/byte caps; published files are bounded to 100.
These are engineering limits, not measured heap or performance acceptance.

Publication uses a latest-value mailbox; source epochs fence admission and queued
callbacks. Exact session/lease identities isolate delayed releases. Runtime
invalidation ends old sessions and clears their snapshots; existing holders must
explicitly reacquire. Production adaptation must preserve activity/summary
interest and coordinate that reacquisition with the runtime owner callback.
Binding equality cannot detect unnotified selection ABA. No private persistence,
MCP fallback or automatic runtime selection exists in this internal reader.
