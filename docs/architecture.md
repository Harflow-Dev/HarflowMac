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

## Harness picker ranking

`AgentUsageRepository` shares lifetime usage across New Session, workflow orchestrator and workflow node menus. One private actor atomically persists counts and processed acknowledgement IDs in one `UserDefaults` value. Acknowledged standalone submissions use task IDs; workflow starts and builder submissions use workflow run IDs. Failed commands, configured nodes, follow-ups, retries and engine-selected fallbacks do not add counts. Exact backend and full model values identify usage; nil and empty model values share the harness-default identity.

Available catalog copies sort by descending count, with binary identity ties and stable identity deduplication. Default stays first in ordinary model menus. Node menus first offer the definition's orchestrator harness when available and its exact model when the current harness supports it, including a supported model shared across harnesses. Menu ordering never rewrites selected candidates, drafts or fallback execution arrays. Counts retain identities that are temporarily unavailable. Model sorting runs outside the main actor; small harness and preferred-option menu permutations use precomputed counts without scanning history.

## Workflow run presentation

Graph keeps a full-height canvas and a resizable inspector (288 pt by default, 420 pt for selected-node activity, within 220–500 pt and with a 400 pt canvas floor). Node selection shows the running or latest attempt and permits selecting earlier attempts. Native executions use their activity reader; on-demand nodes show their call history or Not called. Structural and orchestrator selection retains the run summary. Deselecting restores the default inspector's disclosure and scroll state.

The bottom summary reserves one collapsed line; its bounded scrolling expansion overlays upward without moving the canvas. Parallel retains all current workflow task columns. Selected activity has independent viewport leases and retained per-attempt feed state. Immutable, equality-checked sidebar derivation runs outside the main actor and discards superseded results.

## Approval presentation

Approval presentation follows HarflowDesign `7cf777b`, `scripts/task-approvals.js` and `styles/task-approvals.css`: task states `#approvals/*` and workflow sidebar states `#workflow-run/run-approval-*`. The user-approved correction in `7ddc0cc` uses a single warning outline without a separate left stripe. Readable action values use inset padding, matching the command-block correction in `32e2c4c`. Task cards use stable identities at the Activity feed tail, including source attribution. Summary and Prompt hints navigate to Activity with an explicit reveal and keyboard-focus intent. Workflow cards remain in the default run sidebar.

The task view model owns approval polling and current-task selection. Generation checks discard stale target reads; disappearance cancels polling. Pending cards automatically acquire complete details and use warning treatment, including blocked pending requests. A decision collapses the request into a neutral row, regardless of whether Harflow, the caller or the engine decided it. Structured action rendering retains exact authorization values and unknown keys; incomplete coverage disables approval. The existing backend reason is untrusted text labelled "Agent's stated reason".

`CallerApprovalRepository` uses only public ctl commands. Caller-owned responses require `caller-approvals.monitor-respond.v1` on the fresh invocation handshake; Monitor-owned responses remain ungated on older compatible engines. Unknown owners, states and refusal reasons are not actionable. `awaiting_decision_count` discovers undecided requests; legacy `pending_count` retains its engine meaning. Acquisition remains bounded and does not assume pending rows sort first. Submission uncertainty triggers read-only refresh without automatic resubmission. "Answered from Harflow" identifies the claimed response channel, not authenticated human identity; decision, delivery and execution remain separate facts.

## Group activity presentation

A group-scoped presenter observes membership independently of task completion and derives conversation classification outside the main actor. A single conversation keeps its detail model through resumes and pruning. Adding another independent conversation promotes the mounted group to Parallel until that group is closed or another destination is selected; shrinking membership retains that renderer.

Promotion captures the last applied activity input and presentation before detail teardown. Parallel receives the original rows, Markdown snapshots, shared reading/disclosure/follow state, loaded-member frontier, event boundaries and conversation-history inventory. Visible columns reacquire their own leases and refresh retained activity; the hidden detail owns no polling or leases.

Standalone groups and workflow activity share native horizontal following. A new working conversation or a finished conversation returning to work follows only when the pre-change viewport is within 2 pt of the physical left edge. The relevant lane is leading-aligned after measured layout, retaining its target through subsequent layout reports. Other membership changes preserve the logical reading anchor, and content changes clamp the offset to the document bounds. Horizontal wheel, trackpad, scroller and keyboard intent cancel queued movement; explicit workflow task navigation takes priority. Initial population, ordinary status changes, unrelated reordering, resizing and context switches do not initiate following.

## Streaming Markdown

Task, Parallel, and native workflow activity prepare immutable Markdown blocks outside the main actor. Each conversation row retains its own parser snapshot, keyed by its task and event sequence. Appended text reparses the unresolved suffix; completed blocks retain source-offset identities and prepared inline attributes. Superseded presentation builds cannot publish their parser state. Removed rows and full teardown discard it; hidden visited Parallel columns retain it with their activity snapshot.

The native feed measures the prepared blocks it displays. Completing an unchanged reply retains those blocks and removes the caret from reserved space without changing row height. Static reading surfaces prepare their Markdown asynchronously. Tables use equal-width columns so appended rows do not resize earlier columns.

## Lost-capture activity

`RecoveryEventStreamRepository` wraps captured event streams without changing their tailer, folding or renderer. Activity leases poll the engine's bounded `recovery-activity` command only when supervision reports `lost_with_owner`; summary leases do no recovery I/O. Selected-runtime compatibility, cancellation and generation checks gate each operation and application. Unsupported commands retain captured history.

Recovery pages have independent source IDs and cursors. The adapter maps source identities into a reserved upper integer namespace per lease session, never reuses allocated integers, and retains mappings only for its bounded display snapshot (at most 200 activity records plus provenance and current notices). Returning records retain their identities while displayed; records evicted from the snapshot receive fresh integers if they return later. Source page order remains independent from integer allocation. It forwards ordinary history paging exclusively to the captured repository. Recovery rows carry visible provenance and remain excluded from captured summaries, current activity, usage and task outcomes. A missing transcript produces a recovery notice without making captured history unavailable.

Each recovery session serializes refresh, result application and cancellation on a utility queue. Snapshot publisher callbacks enqueue work without waiting for that queue. Last-lease release invalidates the session synchronously using a short lifetime lock, then queues cleanup; it does not wait for snapshot reads or subscriber cancellation. The sessions dictionary lock covers only membership and reference counts. Generation and runtime checks reject obsolete command work and results.

Inspector notices use the latest engine snapshot for independent capture/input evidence, approximate raw-log cutoff and background idle-bound diagnostics. Engine-reported agent success remains distinct from unfinished background work.
