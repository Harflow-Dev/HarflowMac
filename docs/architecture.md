# Architecture

The Swift packages preserve the coordinator → navigation view → view → view model → use case → repository chain. Shared UI and utilities are in HfFoundation; domain transport remains MonitorCore; repository implementations are in HfCore; feature composition is in HfFeatures. Harflow assembles the application.

Production Module constructs one ManagedRuntimeCoordinator and injects it into ManagedToolEnvironmentRepository and ManagedInstallRepository. Startup consumers join the same attempt; retained failures require explicit retry. MonitorCore owns acquisition, private installation locking, hash verification, offline binary installation, qualification, immutable generations, and external launchers. App ctl/setup access binds the qualified generation; external launchers resolve the active pointer once. External runtime selection and legacy installer controls remain hidden. See [managed runtime](managed-runtime.md).

The local package build packages the app icon and both menu template images, then applies an ad-hoc signature. Developer ID, notarization, distribution, and Xcode Cloud are outside this phase.

Ctl/setup commands and asynchronous store readers validate the selected runtime and lexical state root before operations. See [MonitorCore compatibility](../macos/HfCore/MonitorCore/README.md). Managed readiness precedes those gates; no task history is scanned while preparation or qualification is unavailable.

## Agent picker ranking

`AgentUsageRepository` shares lifetime usage across New Session, workflow orchestrator and workflow node menus. One private actor atomically persists counts and processed acknowledgement IDs in one `UserDefaults` value. Acknowledged standalone submissions use task IDs; workflow starts and builder submissions use workflow run IDs. Failed commands, configured nodes, follow-ups, retries and engine-selected fallbacks do not add counts. Exact backend and full model values identify usage; nil and empty model values share the harness-default identity.

Available catalog copies sort by descending count, with binary identity ties and stable identity deduplication. Default stays first in ordinary model menus. Node menus first offer the definition's orchestrator backend when available and its exact model when the current backend supports it, including a supported model shared across backends. Menu ordering never rewrites selected candidates, drafts or fallback execution arrays. Counts retain identities that are temporarily unavailable. Model sorting runs outside the main actor; small backend and preferred-option menu permutations use precomputed counts without scanning history.

## Workflow run presentation

Graph keeps a full-height canvas and a resizable inspector (420 pt initially, 220–500 pt, with a 400 pt canvas floor). Agent selection shows the running or latest attempt and permits selecting earlier attempts. Native executions use their activity reader; on-demand nodes show their call history or Not called. Structural and orchestrator selection retains the run summary. Deselecting restores the default inspector's disclosure and scroll state.

The bottom summary reserves one collapsed line; its bounded scrolling expansion overlays upward without moving the canvas. Parallel retains all current workflow task columns. Selected activity has independent viewport leases and retained per-attempt feed state. Immutable, equality-checked sidebar derivation runs outside the main actor and discards superseded results.

## Group activity presentation

A group-scoped presenter observes membership independently of task completion and derives conversation classification outside the main actor. A single conversation keeps its detail model through resumes and pruning. Adding another independent conversation promotes the mounted group to Parallel until that group is closed or another destination is selected; shrinking membership retains that renderer.

Promotion captures the last applied activity input and presentation before detail teardown. Parallel receives the original rows, Markdown snapshots, shared reading/disclosure/follow state, loaded-member frontier, event boundaries and conversation-history inventory. Visible columns reacquire their own leases and refresh retained activity; the hidden detail owns no polling or leases.

Standalone groups and workflow activity share native horizontal insertion following. A genuinely new working conversation follows only when the pre-insertion viewport is within 2 pt of the physical left edge. The newest relevant inserted lane is leading-aligned after measured layout. Other membership changes preserve the logical reading anchor. Horizontal wheel, trackpad, scroller and keyboard intent cancel queued movement; explicit workflow task navigation takes priority. Initial population, status changes, reordering, resizing and context switches do not initiate insertion following.

## Streaming Markdown

Task, Parallel, and native workflow activity prepare immutable Markdown blocks outside the main actor. Each conversation row retains its own parser snapshot, keyed by its task and event sequence. Appended text reparses the unresolved suffix; completed blocks retain source-offset identities and prepared inline attributes. Superseded presentation builds cannot publish their parser state. Removed rows and full teardown discard it; hidden visited Parallel columns retain it with their activity snapshot.

The native feed measures the prepared blocks it displays. Completing an unchanged reply retains those blocks and removes the caret from reserved space without changing row height. Static reading surfaces prepare their Markdown asynchronously. Tables use equal-width columns so appended rows do not resize earlier columns.

## Lost-capture activity

`RecoveryEventStreamRepository` wraps captured event streams without changing their tailer, folding or renderer. Activity leases poll the engine's bounded `recovery-activity` command only when supervision reports `lost_with_owner`; summary leases do no recovery I/O. Selected-runtime compatibility, cancellation and generation checks gate each operation and application. Unsupported commands retain captured history.

Recovery pages have independent source IDs and cursors. The adapter maps source identities into a reserved upper integer namespace per lease session, never reuses allocated integers, and retains mappings only for its bounded display snapshot (at most 200 activity records plus provenance and current notices). Returning records retain their identities while displayed; records evicted from the snapshot receive fresh integers if they return later. Source page order remains independent from integer allocation. It forwards ordinary history paging exclusively to the captured repository. Recovery rows carry visible provenance and remain excluded from captured summaries, current activity, usage and task outcomes. A missing transcript produces a recovery notice without making captured history unavailable.

Inspector notices use the latest engine snapshot for independent capture/input evidence, approximate raw-log cutoff and background idle-bound diagnostics. Engine-reported agent success remains distinct from unfinished background work.
