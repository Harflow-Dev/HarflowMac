# Changelog

## Unreleased

- Lower CPU use while tasks run: the streaming caret, the running tool spinner, the working indicator and the live-step pulse in the activity feed now animate in Core Animation instead of redrawing the feed each frame. Their look is unchanged, except that the streaming caret is now hidden from accessibility as decorative.

- Apply the approved transcript design to the task screen and Group view: a centered 696-point reading column, updated message bubbles, prose, tool rows and working row. Collapsed Edit rows now hide their diff until expanded. Parallel and the workflow builder are unchanged.

- Apply the approved composer surface and metrics to the task screen and Group view: a solid surface with a border and shadow in place of glass, 696 points wide, in the same reading column. The field and actions stay in one row and its text is unchanged. The loading skeleton now matches the loaded bubble and composer. Parallel and the workflow builder are unchanged.

- Remove the old segmented control from the task loading skeleton, and unused raw-events views and task tab code.

- Add a `task-changes.v1` client and repository, with a bounded read and an explicit completeness result. It has no callers and no UI; evidence is contract fixtures and fake-runner tests only.

- Insert new activity rows in place instead of reloading the whole table, keeping your reading position, including when rows slide out of the 100-row window. Applies to task, Parallel and workflow activity.

- Add explicit conversation enrollment at launch to MonitorCore, with an outcome type in which an engine error does not imply that no task exists. It has no callers and no durable delivery; evidence is fixtures and fake-runner tests only, with no runtime qualification.

- Sort workflow runs in the sidebar, and place them in Today or Earlier, by the later of their start and the engine's `resumed_at` time. Run pages remain ordered by `created_at`, so an old run beyond the loaded page that is no longer active appears only once paging reaches it.

- Add typed conversation-delivery adapters to MonitorCore for the `conversation-delivery.v1` ctl contract (prepare, send, control) with request values, an outcome type that separates not-dispatched, engine-error and uncertain results, and projection and receipt decoders. They have no callers and no UI; evidence is contract fixtures and fake-runner tests only, with no runtime qualification.

- Select HarflowMCP 0.0.11 as the paired engine, with its frozen runtime inputs and published contract fixtures. Installation and runtime qualification against 0.0.11 are still pending.

- Add the M04 centered composer, adaptive to the window size, and a single scroll area in the sidebar body for navigation, Running and Recent work, with the brand header and appearance/settings footer fixed. The owner accepted its appearance in the real window; 0.0.11 runtime qualification remains open, and the task screen belongs to M05.

- Remove the duplicate system sidebar toggle from the main window, leaving the sidebar's own control. The sidebar card sits slightly lower.

- Match the new-task composer's inner padding to the approved design: 12 points top and right, 8 bottom, 16 left.

- Pair the app with HarflowMCP 0.0.10 (superseded by the 0.0.11 selection above) using qualified frozen runtime inputs and the complete released v1 contract fixture bundle. Preserve public task-list polling; watcher adoption remains separate.

- Add an independently tested internal public-event observation layer with bounded cursor replay, qualified totals and fenced leases; production cutover remains blocked on approved consumer states.

- Add strict public task-event page models and a freshly gated ctl client, preserving normalized loss, cursor accounting and historical provenance for the upcoming shared transport migration.

- Add a typed public task-prompt client and fenced one-shot repository foundation, with the complete released0.0.8 contract fixtures; rendered prompt and runtime adoption remain separate.

- Replace task-list directory watching with an injected public-refresh observation strategy, using one-second urgent and thirty-second hidden-idle polling without overlapping periodic reads.

- Build the app through a thin Xcode host while retaining the shell and guarded tests in SwiftPM; validate the standard macOS dependency-resource layout without changing the managed engine pin.

- Re-vendor the complete S05 canonical v1 contract fixture bundle and verify decoder, capability and fallback compatibility without changing the managed engine pin.

- Fix the connection indicator remaining Disconnected at startup until a task or workflow was selected.

## 0.0.9

- Keep the workflow editor's standalone strip and Add tray on one horizontally scrolling row with the app's thin overlay scrollbar, a fixed scrollbar gutter that never changes the row's height, and a trailing fade for clipped content.
- Reveal that scrollbar while the pointer is over either row and keep it for 1.5 seconds after the pointer leaves, so it can be dragged without a horizontal scroll device.

## 0.0.8

- Pair the app with HarflowMCP 0.0.7 using regenerated frozen dependency inputs and refreshed vendored v1 contract fixtures.

- Keep the selected workflow node's header at the top and composer at the bottom when activity has not started or is unavailable (#48).
- Enable shared workflow answers on compatible engines, preserve drafts after a caller wins, and display answer provenance in run history (#46).
- Post individual macOS notifications for pending questions, approvals, recovery and their answers, plus completed and failed tasks, with persistent delivery deduplication and click-through navigation.

## 0.0.7

- Pair the app with HarflowMCP 0.0.6 using regenerated frozen dependency inputs and refreshed vendored v1 contract fixtures.
- Add a capability-gated Resource slots overview and task phase context, with holders, queues, cleanup evidence, owner navigation and accessible loading states.
- Size user message bubbles to their content within the approved 75% / 420-point width cap, including queued messages (#42).
- Keep native workflow subagent activity at the live end as its content or viewport changes, while preserving a paused reader's position and deferring automatic scrolling during gestures. Align Task and Parallel activity's document-owned bottom spacer with the approved 16-point composer clearance (#44).
- Add Needs you (#30), approved at HarflowDesign `3925e65` (`features/needs-you.html`, `docs/needs-you-proposal.md`): the first Overview row, a list and in-place answer screen, a menu-bar section and notifications for every request Harflow can answer now across tasks and workflows, including nested and child workflows. Waiting-for-caller and unidentifiable-caller requests are never listed. Adds the Settings → General toggle "Notify when a request needs you" (on by default); approval notifications name only the tool. Recovery answers re-check the attention checkpoint before sending; the residual race is tracked in HarflowMCP #97. Deviations from the design: "Started by" shows "Mac app" or "Original caller" because engine 0.0.6 reports no caller identity; and an open request whose source cannot be read for a moment keeps its last detail with "Harflow could not read this request right now." and a Try again link, controls disabled, instead of the expired card. The design does not draw that withdrawn state, so it is pending design sign-off.
- Show queued messages as the user's own bubbles at the end of the activity, captioned Queued, oldest first and newest nearest the composer, replacing the queue strip above the composer on task Activity, each Parallel panel, selected node and Orchestrator Activity, and embedded workflow builder tasks. Streaming output stays above them. A refused Send now keeps the bubble and shows the reason under it; delivered messages appear once in the transcript; undeliverable and uncertain deliveries stay with their caption (#42).
- Remove the workflow builder composer from the workflow window. Builder tasks start from Generate and Edit with agent, and an embedded builder task keeps its own composer. This supersedes the 0.0.6 create/edit builder-composer wording (#43).

## 0.0.6

- Pair the app with HarflowMCP 0.0.5 using regenerated frozen dependency inputs and refreshed vendored v1 contract fixtures.

- Align task notice and continuity rows with shared icon/text columns and spacing (#38).
- Add queued Send, Send now, cancellation and message state to task Activity, each Parallel panel, selected node Activity and workflow builders, qualified by `messaging.v1`. Orchestrator opens Activity on the right; the workflow canvas has no global composer (#32).
- Keep caller-owned, child and internal work discoverable and show workflow controls with engine eligibility and explicit refusal reasons (#39).

- Show Cursor in the New Session fallback grid, harness filter, workflow agent editor, and setup list. Model choices come from `cursor-agent models`. Cursor has no effort control and no turn limit. The v1 wire shape is unchanged.

- Add explicit harness qualification to New session, workflow launch and Settings, with identity-bound evidence, required-feature checks, progress, cancellation and retry. The paired engine 0.0.5 supplies `backend-qualification.v1`; engines without it show unsupported qualification and cannot start new sessions or workflows.

- Remove automatic horizontal movement in standalone and workflow Parallel activity, retaining manual positions across navigation and native remounts while preserving vertical live-follow and panel arrival animation.

- Keep workflow runs ordered by creation time while node activity updates; use this stable fallback until the engine exposes explicit caller-resume timestamps.

- Bound activity-feed hosting lifetimes, skip unchanged reconciliation, and isolate the streaming caret's animation from selectable message content.

- Match the selected running workflow outline to the selection ring while preserving its unselected inset stroke.

- Move retained workflow errors into the sidebar footer so they no longer cover the workflow Summary expand control.

- Show confirmed orchestrator work with the running outline and expose decision history and consultant activity in the workflow inspector.

- Fit selected workflow activity to the inspector width and provide a conversation selector instead of horizontal activity scrolling.

- Resize the Statistics chart to the available window width, adapt controls and rankings in narrower windows, and retain vertical scrolling for long lists.

## 0.0.5

- Pair the app with HarflowMCP 0.0.4 using regenerated frozen dependency inputs and refreshed vendored v1 contract fixtures.
- Add Statistics navigation with start-day ranges, workflow/task/harness rankings, requested-model and repository filters, usage coverage and node breakdowns. Read only the engine's capability-gated public projection; engines without `statistics-page.v1` retain an explicit unsupported state.
- Fix Statistics viewport overflow, picker labels and axis labels.
- Add a chart hover card showing the values under the pointer in Statistics.
- Add a local-time start screen with activity summaries, saved workflow ranking, creation shortcuts and persisted-definition launch preview. Keep summary and ranking unavailable when older engines cannot establish their inputs.
- Show the Harflow emblem in the detail pane before runtime setup completes.

## 0.0.4

- Pair the app with HarflowMCP 0.0.3 using regenerated frozen dependency inputs.

- Increase the minimum Parallel panel width from 420 to 630 points.
- Crossfade loading placeholders into resolved content once per retained selection, with an immediate handoff under Reduce Motion.
- Refresh vendored v1 contract fixtures for additive engine observer-identity diagnostics; existing decoders and version gates remain compatible.
- Prevent recovery activity refreshes from deadlocking task snapshot updates and window teardown.
- Restore horizontal following for new and resumed working conversations, and keep reordered activity within scroll bounds.
- Refresh New session styling when appearance changes and share install-notice dismissal between the sidebar and menu bar. Place the sidebar notice above its controls.

## 0.0.3

- Add capability-gated Harflow responses to caller-owned approvals with additive v1 contracts and typed refusal handling.
- Move task approvals to Activity with complete action details, pending navigation hints and expandable settled rows; retain workflow approvals in the run sidebar.
- Prefer a compact 288-point workflow sidebar and retain 420-point selected Activity, with separate remembered divider widths.
- Apply the canonical product glossary to interface copy and accessibility while preserving public fields and protocol values.

- Pair the current source with engine 0.0.2 and vendor its complete additive v1 state-recovery contract bundle.
- Add sidebar and Settings setup controls with explicit installation/update, shared progress, retained failures and qualified runtime reuse without startup downloads.
- Match the approved first-run setup layout with a scrollable sidebar card, retained appearance/settings footer and setup-required detail pane.
- Add shared store-attention and Settings recovery panels with public inspection, exact-operation confirmation, cancellation, interrupted continuation, partial-backup evidence and retained Finder backup receipts.

- Move engine connection status into the window title bar and simplify the sidebar footer to appearance and settings icons.
- Add a persisted app-wide Light, Dark, or System appearance choice in the sidebar footer.
- Rank agent and model menus by acknowledged app submissions, with supported orchestrator preferences in workflow node menus.

- Promote open single-conversation groups to Parallel when independent conversations join, preserving loaded activity and reading state.
- Follow newly inserted working Parallel columns from the horizontal left edge while preserving readers who have scrolled away.

- Show engine capture/input evidence and background idle-bound diagnostics in inspector notices.
- Add bounded, source-labelled backend transcript recovery activity without changing task outcomes or captured summaries.

- Prepare streaming Markdown incrementally outside the main actor, preserving completed block identities and final reply geometry across task and workflow activity.
- Move Graph activity into a wider selection sidebar with attempt switching, native execution activity and on-demand call history.
- Keep the run summary in a collapsible bottom strip that expands above the canvas.

## 0.0.2

- Fix packaged app startup by loading the managed-runtime specification from the app's standard resource bundle.
- Validate packaged resource startup before release packaging and in macOS CI; the paired engine remains 0.0.1.

## 0.0.1

- Add unsigned release validation and protected product signing, notarization and release-asset workflows.

- Prepare and reuse the exact paired managed runtime with pinned Python and dependency wheels, offline installation, and qualified immutable generations.
- Add shared runtime status and explicit retry; restore readiness-gated Harnesses MCP registration with stable launchers that survive app relocation or removal.

- Set the initial product version to 0.0.1 while preserving v1 wire and storage contracts.

- Extract native macOS packages with preserved source history.
- Adopt Harflow application and Hf module identities.
- Use the supplied Harflow application and menu bar artwork.
- Disable runtime execution and installation pending managed runtime integration.
- Validate explicit Harflow v1 wire identities and per-operation runtime compatibility before commands and store reads.
