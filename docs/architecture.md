# Architecture

The Swift packages preserve the coordinator → navigation view → view → view model → use case → repository chain. Shared UI and utilities are in HfFoundation; domain transport remains MonitorCore; repository implementations are in HfCore; feature composition is in HfFeatures. Harflow assembles the application.

User-facing terminology and retained public compatibility names are documented in
[the terminology guide](terminology.md).

Production Module constructs one ManagedRuntimeCoordinator and injects it into ManagedToolEnvironmentRepository and ManagedInstallRepository. Startup consumers join the same attempt; retained failures require explicit retry. MonitorCore owns acquisition, private installation locking, hash verification, offline binary installation, qualification, immutable generations, and external launchers. App ctl/setup access binds the qualified generation; external launchers resolve the active pointer once. External runtime selection and legacy installer controls remain hidden. See [managed runtime](managed-runtime.md).

The local package build packages the app icon and both menu template images, then applies an ad-hoc signature. Developer ID, notarization, distribution, and Xcode Cloud are outside this phase.

Ctl/setup commands and asynchronous store readers validate the selected runtime and lexical state root before operations. See [MonitorCore compatibility](../macos/HfCore/MonitorCore/README.md). Managed readiness precedes those gates; no task history is scanned while preparation or qualification is unavailable. Startup uses a reuse-only installer check under the permanent lock. Explicit install/update alone permits acquisition. `RuntimeSetupState` publishes equality-deduplicated setup status shared by the sidebar, Settings, and coordinator action gates. The window displays a neutral setup detail until qualified readiness.

## Store recovery

`Module` constructs one `StateRecoveryRepositoryImpl` from the qualified tool environment and injects it into task-list and workflow repositories. Their structured store refusals update a shared, equality-deduplicated readiness snapshot without changing managed-runtime acquisition state. MonitorCore owns only typed public-command models and transport; the repository owns single-flight operations, exact inspection/confirmation binding and generation checks. No consumer writes state files. Settings General consumes the same repository through its use-case adapter and VM, and the sidebar exposes a settings attention entry. Exact inspection values bind inline confirmation and cancellation. Recovery completion rechecks listing and watchers through `runtimeBecameReady()` without invalidating the durable completion receipt; later failures retain the last receipt separately from current recovery state. Finder reveal accepts only that engine-returned completed receipt.

## Application appearance

The window's principal toolbar item shows “Harflow” followed by a 7-point connection indicator, matching the approved populated sidebar state in [HarflowDesign `features/preferences.html` at `191d4df`](https://github.com/Harflow-Dev/HarflowDesign/blob/191d4df/features/preferences.html). Its read-only view model subscribes to task-list, listing-error, and first-listing publishers while mounted and cancels those subscriptions on disappearance; it does not poll or acquire a lease. The indicator keeps the existing connected rule and exposes the harness-rich connection line or listing error as help text. The sidebar footer contains only the appearance and Settings icons; the appearance control keeps its accessible “Appearance” group name and the individual buttons' labels and selection values. `SettingsRepository` stores the choice as `light`, `dark`, or `system` under `harflow.appAppearance`; a missing or invalid value resolves to System without changing other settings. Writes update `UserDefaults` immediately and publish the new snapshot to the sidebar and app shell.

`HarflowApp` creates and retains one `AppAppearanceController` after module initialization and before constructing the coordinator or any scenes. It applies the saved value synchronously, then follows live repository updates. Light maps to `NSAppearance.aqua`, Dark to `NSAppearance.darkAqua`, and System clears `NSApp.appearance` so macOS remains in control. The app-level appearance covers its windows, sheets, Settings scene, menu bar content, and windows created later; feature views do not force a color scheme.

The New session glass material refreshes its identity when the effective color scheme changes, so switching back to Dark does not retain Light material. The install notice sits above the sidebar controls. `ManagedInstallRepository` shares a transient success notice with the menu bar only after an explicit install or update in the current app session. Dismissal or quitting ends that notice; startup reuse of a qualified runtime does not create one. Hiding a notice does not change setup readiness or suppress a future required update.

Harnesses observes runtime readiness separately from install notices. If its initial status load encounters runtime preparation, a later transition to ready reloads the registrations even when no success notice is created. Repeated readiness snapshots and notice dismissal do not trigger extra reloads.

## Harness qualification

`MonitorCore` consumes capability-gated cached qualification plans and explicit feature checks through public ctl commands. Missing `backend-qualification.v1` is unsupported. `QualificationRepository` binds every operation to the selected executable, environment and compatibility context. Per-consumer actor sessions publish equality-checked snapshots, identify the backend/version currently being checked, and reconcile fresh cached evidence after explicit checks. Cancellation and changed request/runtime generations prevent stale adoption; feature and executable identities must match before readiness. Failed command results remain evidence, not launch authorization.

The shared `HarnessQualificationCard` follows approved HarflowDesign `5d48a18`, `features/qualification.html`, across its nine states (approval recorded in `b07b973`). New session, workflow launch and Settings consume independent lifecycle sessions. Opening forms reads cached plans without provider probes; explicit actions check the required feature groups. Workflow qualification precedes ordinary permission preview. Launch rediscovery and runtime-bound repository commands prevent stale evidence from authorizing another executable or selection, while preserving permission payloads and workflow preview hashes. Cancelling stops result adoption; it does not claim to undo engine checks.

Settings routes each action to its backend and keeps qualification separate from MCP registration. Known unavailable task harnesses cannot launch even when no feature checks are required. Workflow requirements and candidates remain engine-owned.

The app selects engine `0.0.5`, which supplies `backend-qualification.v1`. New session and workflow launches require matching successful qualification evidence. Engines without this capability display unsupported qualification and cannot start new launches.

## Harness picker ranking

`AgentUsageRepository` shares lifetime usage across New Session, workflow orchestrator and workflow node menus. One private actor atomically persists counts and processed acknowledgement IDs in one `UserDefaults` value. Acknowledged standalone submissions use task IDs; workflow starts and builder submissions use workflow run IDs. Failed commands, configured nodes, follow-ups, retries and engine-selected fallbacks do not add counts. Exact backend and full model values identify usage; nil and empty model values share the harness-default identity.

Available catalog copies sort by descending count, with binary identity ties and stable identity deduplication. Default stays first in ordinary model menus. Node menus first offer the definition's orchestrator harness when available and its exact model when the current harness supports it, including a supported model shared across harnesses. Menu ordering never rewrites selected candidates, drafts or fallback execution arrays. Counts retain identities that are temporarily unavailable. Model sorting runs outside the main actor; small harness and preferred-option menu permutations use precomputed counts without scanning history.

## Workflow run presentation

Sidebar workflow recency uses `created_at` for sorting and Today/Earlier bucketing. Internal `updated_at` writes never change recency. Active runs remain in Running and return to the creation-time bucket when settled. This is the stable fallback until the engine exposes a public caller-resume timestamp (HarflowMCP #68); no undocumented timestamp is consumed.

Graph keeps a full-height canvas and a resizable inspector (288 pt by default, 420 pt for selected-node activity, within 220–500 pt and with a 400 pt canvas floor). Node selection shows the running or latest attempt and permits selecting earlier attempts. Native executions use their activity reader; on-demand nodes show their call history or Not called. Structural selection retains the run summary. The standalone activity direction is documented in `HarflowDesign` commit `cd7f497` (`scripts/workflow-run.js`, `styles/workflow-run.css`, orchestrator-decisions, orchestrator-idle and consultant-activity states). Orchestrator selection projects its decision activations separately from the worker Parallel inventory. It defaults to a confirmed running decision, otherwise the latest decision, and retains an explicitly selected earlier decision across polling. Standalone running outlines require a task attempt with reported running status; reservations, activation status and the Deciding subtitle do not establish liveness. The detached sidebar projection prepares standalone status before rendering. On-demand calls associate activity by exact execution ID, retain call history and details, and show unavailable activity when that association is missing. Deselecting restores the default inspector's disclosure and scroll state.

The bottom summary reserves one collapsed line; its bounded scrolling expansion overlays upward without moving the canvas. Parallel retains all current workflow task columns. Selected activity follows the owner-requested width refinement in `HarflowDesign` commit `1fa3da2` (`scripts/workflow-run.js`, `styles/workflow-run.css`, `selected-node` and `selected-conversations`). It fits the inspector width and uses a native conversation selector when several conversations exist. Its cached activity VM retains the selected conversation and visited reading state, leases only that conversation while visible, and releases leases while hidden. Membership changes preserve a valid selection; removal falls back to the first remaining conversation. The inspector has no horizontal activity scroller. Immutable, equality-checked sidebar derivation runs outside the main actor and discards superseded results.

## Approval presentation

Approval presentation follows HarflowDesign `7cf777b`, `scripts/task-approvals.js` and `styles/task-approvals.css`: task states `#approvals/*` and workflow sidebar states `#workflow-run/run-approval-*`. The user-approved correction in `7ddc0cc` uses a single warning outline without a separate left stripe. Readable action values use inset padding, matching the command-block correction in `32e2c4c`. Task cards use stable identities at the Activity feed tail, including source attribution. Summary and Prompt hints navigate to Activity with an explicit reveal and keyboard-focus intent. Workflow cards remain in the default run sidebar.

The task view model owns approval polling and current-task selection. Generation checks discard stale target reads; disappearance cancels polling. Pending cards automatically acquire complete details and use warning treatment, including blocked pending requests. A decision collapses the request into a neutral row, regardless of whether Harflow, the caller or the engine decided it. Structured action rendering retains exact authorization values and unknown keys; incomplete coverage disables approval. The existing backend reason is untrusted text labelled "Agent's stated reason".

`CallerApprovalRepository` uses only public ctl commands. Caller-owned responses require `caller-approvals.monitor-respond.v1` on the fresh invocation handshake; Monitor-owned responses remain ungated on older compatible engines. Unknown owners, states and refusal reasons are not actionable. `awaiting_decision_count` discovers undecided requests; legacy `pending_count` retains its engine meaning. Acquisition remains bounded and does not assume pending rows sort first. Submission uncertainty triggers read-only refresh without automatic resubmission. "Answered from Harflow" identifies the claimed response channel, not authenticated human identity; decision, delivery and execution remain separate facts.

## Group activity presentation

A group-scoped presenter observes membership independently of task completion and derives conversation classification outside the main actor. A single conversation keeps its detail model through resumes and pruning. Adding another independent conversation promotes the mounted group to Parallel until that group is closed or another destination is selected; shrinking membership retains that renderer.

Promotion captures the last applied activity input and presentation before detail teardown. Parallel receives the original rows, Markdown snapshots, shared reading/disclosure/follow state, loaded-member frontier, event boundaries and conversation-history inventory. Visible columns reacquire their own leases and refresh retained activity; the hidden detail owns no polling or leases.

Standalone groups and the workflow Parallel view retain coordinator-owned horizontal pixel positions across native remounts and navigation. New and resumed conversations and membership reordering preserve that numeric offset. Removal and resizing clamp only to the available document range. Restoration waits for measured layout, and user input or explicit workflow task navigation takes priority. The Graph inspector uses explicit conversation selection instead. Vertical live-follow and panel arrival animation remain independent.

## Streaming Markdown

Task, Parallel, and native workflow activity prepare immutable Markdown blocks outside the main actor. Each conversation row retains its own parser snapshot, keyed by its task and event sequence. Appended text reparses the unresolved suffix; completed blocks retain source-offset identities and prepared inline attributes. Superseded presentation builds cannot publish their parser state. Removed rows and full teardown discard it; hidden visited Parallel columns retain it with their activity snapshot.

The native feed measures the prepared blocks it displays. Completing an unchanged reply retains those blocks and removes the caret from reserved space without changing row height. Static reading surfaces prepare their Markdown asynchronously. Tables use equal-width columns so appended rows do not resize earlier columns.

## Lost-capture activity

`RecoveryEventStreamRepository` wraps captured event streams without changing their tailer, folding or renderer. Activity leases poll the engine's bounded `recovery-activity` command only when supervision reports `lost_with_owner`; summary leases do no recovery I/O. Selected-runtime compatibility, cancellation and generation checks gate each operation and application. Unsupported commands retain captured history.

Recovery pages have independent source IDs and cursors. The adapter maps source identities into a reserved upper integer namespace per lease session, never reuses allocated integers, and retains mappings only for its bounded display snapshot (at most 200 activity records plus provenance and current notices). Returning records retain their identities while displayed; records evicted from the snapshot receive fresh integers if they return later. Source page order remains independent from integer allocation. It forwards ordinary history paging exclusively to the captured repository. Recovery rows carry visible provenance and remain excluded from captured summaries, current activity, usage and task outcomes. A missing transcript produces a recovery notice without making captured history unavailable.

Each recovery session serializes refresh, result application and cancellation on a utility queue. Snapshot publisher callbacks enqueue work without waiting for that queue. Last-lease release invalidates the session synchronously using a short lifetime lock, then queues cleanup; it does not wait for snapshot reads or subscriber cancellation. The sessions dictionary lock covers only membership and reference counts. Generation and runtime checks reject obsolete command work and results.

Inspector notices use the latest engine snapshot for independent capture/input evidence, approximate raw-log cutoff and background idle-bound diagnostics. Engine-reported agent success remains distinct from unfinished background work.

## Loading handoff motion

Loading handoffs follow the owner-approved [HarflowDesign rule at `d975810`](https://github.com/Harflow-Dev/HarflowDesign/blob/d975810/docs/loading-handoff.md), states `foundations/skeleton-crossfade/light` and `dark`. Shared HfUI presentation uses `HfMotion.arrival` (180 ms ease-out) for simultaneous skeleton-out/content-in opacity, with an immediate swap when `hfReduceMotionOverride ?? accessibilityReduceMotion` is true. The selection identity owns the reveal; streaming, pagination and retained viewport reentry do not replay it.

Deferred content preserves its first presented placeholder frame before constructing expensive content. Prepared content keeps its identity through the reveal, and decorative skeletons never accept interaction or accessibility focus. Inline content retains natural sizing, including omission of an available-empty Files edited section. The outgoing task skeleton stops publishing native toolbar items once prepared content owns that chrome, avoiding duplicate AppKit identifiers. The native sidebar keeps its existing reconciler: replacing its diagnostic skeleton with unrelated rows does not retain removed cells or add a competing overlay.

Parallel panel sizing follows the owner's [630-point minimum amendment at `ac15a82`](https://github.com/Harflow-Dev/HarflowDesign/blob/ac15a82/docs/loading-handoff.md#parallel-panel-width-amendment): standalone group and workflow Parallel lanes share the floor, divide wider available space evenly, and scroll horizontally when the minimum does not fit. The Graph activity sidebar keeps its separate width.

## Start screen

The ready runtime's unselected detail pane follows HarflowDesign `62b9675`,
`scripts/start-screen.js` and `styles/start-screen.css`, states `tasks/start` and
`tasks/start-no-workflows`. Runtime setup retains its existing welcome view.
The coordinator retains one `StartScreenVM` across selection changes so its
monotonic refresh throttle survives rebuilt views. The VM owns visibility,
subscriptions and one bounded history scan; an
actor folds immutable public pages and computes equatable presentation off the
main actor. Disappearance cancels structured work and invalidates its generation.
Semantic task and history-readiness changes hide invalidated metrics immediately.
Readiness deduplication excludes pagination cursor and loading churn. Definitions
publish alphabetically as soon as their independent read completes, even when
history remains pending or its metric generation was invalidated. A separate
mount token rejects all definition callbacks after disappearance. Identical ready
definition polls retain complete metrics without an intermediate loading state;
identity, revision and content changes remain observable. Definition failures
clear cached choices so retry cannot resurrect stale rows. A minimum 30-second
monotonic interval between scan starts coalesces changes and catches external definition
and workflow updates. Production snapshot replays are suppressed after semantic
fingerprint deduplication on a utility queue; only later content changes
invalidate the scan. A separate clock pulse recomputes local greeting and date
windows without reading history; late generations cannot restore invalid metrics. Complete presentation is derived
off the main actor before loading and presentation are applied together without
suspension.

Task and workflow primary pages are independent of sidebar pagination. Each
source permits at most 100 pages, 10,000 received primary records and a cooperative
30-second deadline, checked before and after each await. Commands retain their
own bounded timeout. Readiness, authority, count completeness, advancing cursors
and consistent duplicate identities are required; partial totals are never shown.
Pages are eventually consistent, not a frozen history transaction.

Only exact `running` standalone tasks and non-settling root saved-workflow runs
contribute to running totals. Workflow-owned tasks, builder runs and nested runs
are excluded. Task ownership requires explicit `workflow_run_id: null` for a
proven standalone task; absent or malformed ownership stays unknown. Terminal
tasks require an ISO completion timestamp. Terminal workflows require numeric
`finished_at` and must not be settling. A legacy terminal workflow can age out of
the seven-day summary only when finite `created_at <= updated_at <= now`
evidence places `updated_at` strictly before that cutoff; it is never used as a completion date. Missing terminal task timestamps
have no equivalent safe upper bound and keep the summary unavailable.

Ranking counts retained root saved-workflow starts by pinned `workflow_id`,
independent of outcome, against current saved-definition identities. Unknown
classification or identity makes all rankings alphabetical without counts.
Modern identities distinguish deletion and recreation; historical engine identity
fallbacks may retain same-name ambiguity. The app's engine pairing is unchanged;
older paired engines intentionally omit metrics they cannot establish.

The coordinator owns a transient workflow runner name, cleared on dismissal or
another modal. A row opens the existing runner, waits for a fresh saved-definition
list, loads that persisted definition, and enters permission preview. A missing
initial definition leaves the chooser available. No start-screen action executes
a workflow automatically or reads an editor draft.

## Needs you

Needs you follows HarflowDesign `3925e65`, `features/needs-you.html` and `docs/needs-you-proposal.md`. `NeedsYouRepository` (HfRepository) is the single source for the sidebar badge, the screen, the menu-bar section and notifications. It is started once at launch, after task listing, and waits for the managed runtime through the shared tool environment. Each pass is single-flight and bounded to 24 `harflow-ctl` invocations: it pages active workflow headers (up to 10 pages) and active tasks (up to 4), reads at most 12 candidate roots with `workflow-status --monitor-view` in least-recently-visited order, checks active tasks with one `status-batch` per 100, and lists and fetches approvals only for tasks whose `approval_summary` awaits a decision. Work that does not fit rotates into later passes and is reported as deferred, which makes the count a lower bound without raising an error notice. Cadence is 3 s while the window or popover is visible and 15 s otherwise, with an immediate pass on becoming visible, after an answer and on Retry.

A source is read as ready, unreadable or unqualified (bootstrap, blocked catalog or missing `interaction_state`). Only ready reads produce items. An unreadable source withdraws its items without resolving them, so a failed read never removes a notification or re-notifies when the source returns. A request is listed only when the engine reports `monitor_available` with a recognized owner (Monitor, or a caller proven dead); unknown wire values are never answerable. For a root, the selected checkpoint also needs `monitor_controls.resume.allowed`; sibling checkpoints rely on the engine's recheck at submit. Usage-limit buttons come only from the source run's own `usage_limit_recovery`; otherwise the request is ordinary free text. Approvals use the same shared eligibility predicate as the task view (`CallerApprovalRequest.isEligibleForMonitorResponse`). Answers go through `workflow-resume <root> --monitor` (with `--decision-id` for questions) and `approval-respond`; approvals are re-read and compared with the displayed request before sending. The screen sends exactly the item it rendered and shows the refreshed item with a review note when the live item moved on. Notifications start only from events: items present in a source's first ready observation during startup never notify.

Needs you adds `MonitorDestination.needsYou(itemID:)`; every Needs you selection highlights the one sidebar row. See the [HfRepository README](../macos/HfCore/HfRepository/README.md) for the `needs_you_item` and `needs_you_list` user-info keys.

## Statistics

Statistics follows the approved original HarflowDesign `1b1d5d8` / `1c32c2e`, `scripts/statistics.js` and `styles/statistics.css`, overview/system and existing node breakdown compositions. The owner-requested responsive-width refinement (`HarflowDesign` commit `8b4605d`, `styles/statistics.css`, overview and node states) removes the horizontal content minimum: the plot fits the detail viewport, controls adapt to narrower widths, and long rankings remain vertically scrollable. The sidebar's native reconciler owns a stable Overview → Statistics destination; the main-window coordinator retains its VM and selections across navigation.

MonitorCore gates every `statistics-page` call on a fresh `statistics-page.v1` capability handshake. `StatisticsRepository` uses constructor-injected tooling and state recovery, never private persistence or activity replay. The managed engine pin stays unchanged. Unknown wire states and incomplete history do not authorize aggregates.

A dedicated actor walks at most 200 pages / 20,000 facts, rejects duplicate facts and repeated cursors, and retries an expired snapshot twice. Preparing responses are bounded and cancel when the screen disappears. Generation checks reject stale mounts, ranges and filter projections. Grouping, sorting, calendar bucketing and immutable presentation derivation run outside the main actor; the VM applies only changed presentation values. Visible screens refresh every 30 seconds; disappearance stops polling and reappearance starts a fresh read.

Workflow cohorts use the engine's finished-root start day; all descendants retain that root cohort. Standalone initial/retry/resume executions retain their own cohort. Calendar day arithmetic supplies UTC query bounds and handles daylight-saving changes. Repository filters use collision-safe exact identities, including Unknown. Workflow cohorts filter by the recorded root repository and retain descendant context even when executions use another repository. Standalone executions filter by their own repository. Saved workflow rankings group stable workflow identity across repositories and revisions; each run preview retains its actual repository and revision. Missing requested models display Unknown without substitution. Unfiltered time combines workflow wall time and standalone execution time; harness/model filters use only matching execution time. Independent duration and usage contribution gates prevent native owner copies from double counting while preserving elapsed duration when tokens are unavailable. Qualified independent token contributions form a known subtotal; unavailable usage is excluded and selected-record coverage remains explicit. Execution-scoped category evidence is grouped by harness with coverage for each category, excluding unknown cumulative scopes. Native logical records remain visible in counts and drilldown with owner attribution. Missing accounting, history completeness and retained-history coverage are separate disclosures. No screen computes metrics or performs I/O.

## Retained workflow errors

Design reference: `HarflowDesign` commit `e8d7559`, `scripts/workflow-errors.js` and `styles/workflow-errors.css`, zero, one, three and open-details states.

The root presentation modifier remains the single owner of `IncidentPresentation` and injects that same observable instance through the optional `incidentPresentation` environment value. Outside a presentation context the value is nil. The sidebar does not create another store or install another context.

The shared sidebar footer presents retained source failures above appearance and Settings in both runtime-ready and setup layouts. Its entry is hidden for zero failures. The bounded details popover reads live failure messages and retry actions, retains details after the top notification is dismissed, and closes when the last source recovers. Retry dispatch resolves the current failure by identity so a replaced operation-bound action is not captured indefinitely. The top snackbar, alerts, dialogs and source-scoped recovery behavior are unchanged. No retained-errors control floats over the detail pane or Summary bar.

## Task supervision and continuity

The approved reference is HarflowDesign commit `fcc51ab`, `features/task-continuity.html` and `docs/task-continuity.md`, states normal, surviving, details, uncertain, capture, input, both, completed, absent, unsupported and invalid-time in both appearances. A neutral secondary row below the header is shared by Activity, Summary and Prompt; it does not contribute to warning counts. Only explicit qualified adoption with a running task, live owner, live capture and known compatible input permits the running claim. A draining exited process with a live owner does not imply dispatcher loss. Actual owner uncertainty, capture loss and input loss remain warnings.

Status reads request `--observer-parent` so a long-lived app process, identified by PID and start identity, observes surviving execution rather than inventing a generation for each ctl poll. Usage-error responses fall back to the older status command. Missing and malformed optional adoption fields produce no row. The managed runtime pins engine 0.0.5, which supplies qualified parent-observer continuity evidence. No runtime version is inferred from status reads.

The coordinator owns session memory shared by task-detail VMs, retaining recent task-scoped restart observations (up to 256 tasks, 32 observations per task), deduplicating previous identity, observer kind and observing identity independently of nullable timestamps. Terminal or unhealthy evidence hides the running claim while preserving diagnostic history. Details opens Technical info → Supervision, scrolls to it and requests keyboard and accessibility focus only on explicit user activation. No live announcements accompany polling. Details includes owner/process/capture/input evidence and raw-log cutoff diagnostics; healthy cutoff metadata is not a warning. Parent observations use “Current observing process” and “Observing process started at”, true MCP observations use server labels. Valid timestamps use local time; absent or malformed dates have no invented fallback.
