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
| `TaskChangesRepository` | One-shot typed reads of a task's stored repository differences (all listing pages, or one row's whole patch) through `task-changes.v1`, bound to selected tooling and a caller fence; results are keyed by task id and caller generation, cursor expiry restarts from the first page, and pending captures are re-read by the caller. A read that reaches its own 64 request or 120 second bound fails with the typed `clientBound(.requestBudget | .deadline)` outcome, which is not an engine failure and is not reported to state recovery; a per-command transport timeout stays `failed(.timedOut)`. No cache, persistence or file access; diff text is not retained. |
| `TaskSnapshotRepository` | Per-task `harflow-ctl status` snapshots. |
| `EventStreamRepository` | Ref-counted per-task event tailing, shared across every screen watching the same task; also publishes each task's `EventAvailability` (`loading`/`available`/`unavailable`), so a caller never has to infer "the log couldn't be read" from an empty event list. |
| `StateRecoveryRepository` | Shared structured store refusals and explicit inspection/confirmation/recovery lifecycle; single-flight operations and stale-result checks remain independent of managed acquisition. |
| `TaskListRepository` | Bounded public task-history/status reads, titles, action refresh barriers, replaceable invalidation observation and `detail()` precedence. |
| `FinishNotifier` | User notifications for roots that finished since the last listing. |
| `TaskContinuationRepository` | App-session Continue attempt ownership and explicit bounded recorded-successor checks consumed by the standalone task screen. |
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

## Captured observations and stored requests

`EventStreamRepository` consumes `task-events` through a shared per-task public
session. Activity and cumulative summaries no longer open engine event files.
The repository publishes one atomic `EventObservationFrame` containing bounded
normalized records, strictly projected rows, source/window identity, history
health and independently qualified optional totals. Unknown or unsupported
payloads remain raw evidence; missing success/text fields never become successful
empty output. Conservative continuity barriers prevent matching through unknown
intervals. Producer sequence numbers remain data, while session/source/window and
file-order admission identify presentation occurrences.

One newest bootstrap supplies a shared opaque cursor lineage for activity and
bounded oldest-seek/chronological-summary replay. Observed totals never certify
complete execution capture. Summary-only roles continue summary work without
materializing activity. A bounded activity window can remain cached while a
summary role survives; rejoining activity resumes its retained cursor and identity.
The last role releases the session and clears its holder.

Admission is single-flight per session and globally two event operations. Each
one-second tick admits at most two forward activity pages and two summary-tail
pages. Historical seek/replay/recovery has a cumulative 4096-operation ceiling.
Activity admits whole pages up to 2000 records/4MiB serialized bytes, retaining the
last delivery cursor at capacity. Summary keys/call identities have independent
bounds and expose at most100 files. These are engineering limits, not measured
heap or runtime performance acceptance.

Read failures/nonprogress require explicit read retry. Invalid cursors retain
cached source-A rows and require explicit source adoption. Capacity-only rebasing
changes the consumer-window identity while preserving independent summary facts.
Known loss remains sticky. Runtime transitions synchronously fence cached facts,
queued publications and prompt work, then reacquire retained activity/summary role
interest. Exact role/session identities prevent delayed releases from affecting a
replacement session; binding comparison alone does not establish ABA safety.

Stored assignment text comes only from the separate typed `task-prompt` reader.
Initial reads request65536 bytes; Read more requests a replacement prefix bounded
to131072 bytes. State, integrity and completeness remain independent. Captured
display prompts and recovered text are never assignment authority. Recovery
publishes a separate display-only transcript and never contributes captured counts.

Every public operation retains a fresh capability handshake. Fixture adoption from
engine0.0.8 does not select that runtime: the managed engine remains pinned to0.0.7,
with explicit unsupported states and no private/MCP fallback or automatic acquisition.

Status read outcomes carry globally ordered attempt revisions independently of retained display
snapshots. Equivalent successes and failures invalidate outcome readers; old single/batch results
and evicted reads are fenced. The revision getter uses an independent clock with no callbacks.
New outcome/eviction invalidations publish outside snapshot state locks. Task actions keep
acknowledged Stop requests for the app session across VM navigation, qualify them only with a
post-ack Running/alive-owner read, and clear them for unavailable/non-running/taken-over/evicted
or superseded members. They never imply signals were delivered or settlement completed. Current
member checks use conversation continuation links. Stopping invalidations publish only qualified
set changes; idle reads skip outcome scans when no Stop request is tracked.


## Continue attempt ownership

`TaskContinuationRepository` is shared by production composition and keeps immutable invocation
outcomes independently of later recorded-successor checks. Requests capture a selected runtime,
conversation and full source ID. An exact loaded task identity or retained healthy recorded-path identity in the same runtime is
required; the engine still decides eligibility. The repository serializes per runtime/conversation and also deduplicates source aliases.
Generic task busy is held only during an invocation, not indefinitely while its outcome is uncertain.
Future UI must query this owner as well as current status authority before enabling actions.

An acknowledged or uncertain source is not launched again during this app session. Navigation and
runtime A→B→A retain its evidence. A different source needs a healthy recorded direct-successor
bridge from the previous admitted source when earlier unsafe evidence exists. This permits an
explicit next-turn operation without rewriting the older outcome or claiming which invocation
created a successor. Multiple successors are returned as evidence; none is selected automatically.

Checks are explicit and use only the runtime-bound public successor API. A traversal admits at most
four pages/400 rows, including related headers, with cursor/duplicate checks and a 120-second
monotonic budget checked before and after each page await. This is not a preemptive deadline for
a suspended dependency. Only direct items establish bridges. Empty, incomplete, unknown-readiness,
failed or bounded reads cannot prove that no pending launch exists. Prior healthy edges survive
later failed/cancelled checks. At most 400 proof IDs per attempt and 256 attempts are retained;
capacity refuses new admission instead of evicting unsafe evidence.

This is app-session state, not disk persistence or relaunch recovery. Runtime tokens include the
effective child environment and are kept in memory, not logged or persisted. The safe Null default
never dispatches. The standalone task screen consumes owner state for composer locking and launch/refusal presentation.

The targeted check overload can prove a requested later source through multiple recorded hops,
sharing the same four-page/400-row/120-second budget across the whole traversal. Each expanded
predecessor must be healthy and complete; direct items supply edges, never related headers.
Reachable-source proof is retained separately from direct successors and shares the 400-ID cap.
A proof for A→B→C permits an explicit C operation without launching B or attributing C to A's
invocation. The targeted read never certifies that all descendants were discovered.

## Pending launches

`PendingLaunchRepository` owns explicit public pending inventory and exact full-ID lookup separately
from Stop invocation evidence. Acquire a read lease only while its feature is visible, bind the
selected full ID, and synchronously clear/rebind that selection on every navigation change. Releasing
the lease revokes delayed reads and drops that lease's stored lookups (Stop attempts are kept); there is no namespace polling timer. Refresh traverses from the first
page with at most64 requests,120 cooperative seconds and8MiB of conservatively charged response
bytes (128KiB per request), including one cursor-expiry restart. Inventory retains at most4096 rows
and8MiB of encoded raw payload. Incomplete/failed reads keep prior rows visibly stale; only a fresh,
fully understood complete traversal replaces them. Empty lookup or inventory never proves settlement.
Unsupported future rows preserve healthy neighbors and prevent a completed-check claim.

A recorded lookup only presents record-found evidence. Explicit `resolveRecorded` performs a fresh
same-full-ID ordinary status read and uses `TaskListRepository.admitRecorded` with a shared synchronous
selection/runtime admission gate before history insertion. It reads the retained conversation chain
through `continuation_of_task_id`, falling back to `parent_task_id`; unrelated `spawned_by` is not a
conversation link. The entire chain must qualify in the same captured runtime before atomic insertion:
at most32 sequential public status operations,120 cooperative seconds and8MiB encoded row evidence.
Each operation retains the existing public status handshake/fallback behavior. These are read bounds,
not a preemptive timeout. Missing/pruned/unqualified ancestors, cycles, bounds or inconsistent root
ordering return explicit `PendingRecordedAdmissionFailure`; no partial target/ancestor insertion or
fabricated recovered root occurs. This conservatively refuses handoff when retained ancestry cannot
establish the existing conversation namespace. It never invokes legacy `resolve` or uses cached task
status for routing. The caller must also recheck its selected context before navigation.

Pending snapshots and task-history listings use nonblocking publication drains. Synchronous raw
snapshots/list getters update before a successful refresh returns; serialized whole delivery waves
run outside owner/state/admission locks. Nested or concurrent publication requests update the next
wave instead of recursively delivering it. Task history rejects captured publications older than its
accepted revision, so a delayed handoff cannot overwrite newer normal-refresh rows/status. A subscriber
holding a delivery callback open can delay the next delivery wave, while current raw getters remain
available for action/routing guards. Equivalent task polls still publish nothing. These two channels
use CurrentValueSubject directly rather than adding wrapper locks around subscriber callbacks.

Stop preparation mints a single-use confirmation with captured runtime/fullID/launch generation.
Submitting transfers ownership to the repository; subsequent navigation cannot cancel that request.
Fresh pending preflight and the client's paired pending/cancel capability handshake precede ordinary
full-ID cancel. A record found during preflight invalidates the pending operation. A spawn after
preflight can race that ordinary cancel; this is not an atomic generation-conditioned mutation.
Generic task busy excludes other commands only during invocation. Accepted, uncertain and engine-error
evidence survives independently of later reads and runtime changes; acknowledgement never proves
stopped, and observed settlement differs from positive never-started evidence. Continue state is untouched.

Read leases are capped at8, in-flight inventory traversals at2 (including revoked readers), and exact
reads at8 globally/one per lease. Lookup cache is capped at128 entries/2MiB encoded payload, and retained Stop attempts
at256 records/16MiB payload including captured identity. Stop admission reserves one maximum1MiB result
and a32KiB diagnostic capsule before dispatch, then releases unused reservation to the actual retained
payload cost. Capacity refuses rather than evicting unsafe evidence. Structured engine reasons and raw
receipts stay verbatim; shortened unstructured diagnostics carry both a textual marker and the
`diagnosticsTruncated` flag. These are bounded payload budgets, not measured heap ceilings. Bind runtime
notifications inline so A→B→A revokes old work. Snapshot `currentRuntime` is an in-memory comparison
binding only; filter retained attempts by it and full ID, and never display or log its environment.
