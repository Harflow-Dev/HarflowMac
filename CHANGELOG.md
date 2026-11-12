# Changelog

## Unreleased

- Show a dot where a Parallel group's enforcement sentence does not fit (HarflowDesign `4ff7d83`, `lanes-titled-minimum`): at the minimum window the top bar keeps its title and badge whole and draws a 6 point dot in a 16 point keyboard target; VoiceOver reads the sentence from the dot, and hovering or focusing it shows the sentence in a popover that Escape dismisses until the pointer and focus have left. A window wide enough to show the sentence shows no dot, and neither does a loading or empty group.

- Draw the Parallel group's loading state on the approved frames (HarflowDesign `4ff7d83`, `2934681`): until the group's membership is known the screen shows two (or the known number of) lanes with their real heads, bodies, separators and a disabled message box as placeholder blocks, one VoiceOver element "Loading Parallel group", so the lanes do not move when the group resolves. The window's top bar shows the group name with placeholder badge and meta blocks (the meta block drops at narrow widths) and View prompt and Cancel all are disabled meanwhile. A group with no tasks then shows "No tasks in this group any more." in place of the old placeholder view. The top bar content is handed from the loading state to the resolved group in place, never blank in between.

- Settle Parallel lanes on the approved states (HarflowDesign `4ff7d83`): a finished lane ends its feed with one line after any queued messages and the outcome ("Done · 04:51", "Failed · 07:48", "Cancelled · taken over · 04:31", "Done · exit not observed"), in success, danger or secondary tone; the tinted result card is gone from lanes (the Graph inspector keeps it). A lane with no activity says "Activity log unavailable." or "No activity to display." in the lane's body text. View prompt now works in lanes: while it is on, each visible lane reads its conversation's stored first request through the engine and shows it expanded above the feed ("Original request", with copy, partial and unavailable forms), capped at 40 percent of the lane and scrolling inside. A lane's outcome line is no longer announced again when you return to the group, and the lane title stops being a Tab stop if focus after "Load current activity" does not land.

- Keep Parallel lanes clear of the floating sidebar: with the sidebar shown, the group screen's lane row started at the window's left edge, so lane 1 sat under the sidebar and the viewport was wider than the lane budget. The lane row's offsets and viewport width are now measured inside its scroll view's content inset, so lane 1 starts at the sidebar's edge, the lanes fill to the window's trailing edge, and a sidebar collapse or expand keeps the reader's position in points (the lane stride changes with the width, so the reader can land partway into another lane). The workflow run's Parallel mount and the Graph inspector are unchanged.

- Move the Parallel group's name, status badge and enforcement sentence into the window's top bar, approved at HarflowDesign `4ff7d83`: the badge counts the agents ("1 running · 2 done", "3 done", "2 done · 1 failed", "2 done · 1 cancelled" in running, done, failed and neutral tones, no icon unless something runs) beside "Enforced for every agent here: Network: not controlled." (or "Enforcement differs between these agents; see each task's details."). The sentence is whole or dropped when the window is narrow, never shortened. View prompt is a ghost button (disabled and pressed-marked as appropriate) and Cancel all a danger button shown only while something runs; Cancel all now confirms with Cancel and Cancel all. The content header, enforcement pills and claim strip are removed, so the lanes start under the toolbar, and an empty group shows "No tasks in this group any more." with View prompt disabled.

- Redraw Parallel lane messaging on the approved lane states (HarflowDesign `4ff7d83`): the composer is one row (a field and a 28 point send button) that queues only, labelled "Message Claude" with send "Send to Claude" and named "Message Claude: <task title>" for VoiceOver; it stays enabled on a settled lane, is locked with a lock icon on a taken-over lane, and shows "Messaging is unavailable for this activity view." when there is no way to send. Send now, the printed hint and the glass surface are gone from lanes (the task and selected-node message boxes keep Send now). A lane's outcome line ("Queued message cancelled.", "Delivery is in progress.") now sits at the end of the feed after the queued bubbles instead of above it, announced when it changes; while the lane is loading it sits above the composer.

- Redraw the Parallel lane head and history notice on the approved lane states (HarflowDesign `4ff7d83`; states `2153ab1`, `lane-history-boundary` `a39ee63`): one row with the status glyph, the task title (two lines at most), a caption of harness and model (plus "taken over") and a status caption ("Running 03:24", "Done 04:51"), and a Lane actions menu holding Open task. The inline Take over in terminal button, Open task link, repository and turn subtitle, status capsule and head spinner are gone from lanes; Take over stays on the task screen and the Graph inspector. The always-on "Available captured history" line is removed: a lane shows a bordered boundary block with "Load current activity" only while its cached history is not current, and focus returns to the lane head when it completes. The feed no longer overlaps the block above it.

- Draw Parallel lanes on the approved v2 frames (HarflowDesign `2934681`): a 360-point minimum width at every window size (was 630), the page background with a 1-point border separator and no status strip, and a head, body and foot frame. A minimum-size window now shows two whole lanes and a peek of the third, and moving keyboard focus into a lane scrolls it fully into view. The same lanes appear in workflow run Parallel; the Graph selected-node inspector keeps its earlier look. More lanes are visible at a given window width, so a visible group leases the activity of more conversations at once (about one and a half times at common sizes). The opt-in Parallel benchmark fixture now uses the current event envelope and takes its viewport width from `HARFLOW_PARALLEL_BENCHMARK_WIDTH`.

- Draw Parallel lane activity with the task screen's transcript metrics at the lane's insets (16 point sides, 12 point row gap, no reading column cap): 22 point prose lines, 28 point tool heads, the single-dot working row. The "N activity items" count line is dropped from lanes; pagination, live follow, queued messages and the Graph inspector's activity are unchanged.

- Fix a launch crash: the standalone task detail's status-read publisher ran a main-actor-isolated operator closure on the first listing refresh, which sends from a background context and trapped the isolation check about two seconds after start. The operator now lives in a nonisolated helper, and the Harnesses readiness pipeline hops to the main queue before its operators. Adds a regression test that sends from a detached task, and an architecture rule for Combine operators in main-actor types.

- Open the Mac app directly from `macos/Harflow.xcodeproj`; the wrapper workspace is removed. Each Swift package appears as a folder under HfFoundation, HfCore and HfFeatures in the project navigator with its own shared scheme, and the HarflowHost scheme runs the package tests through one test plan (MainWindowFeature, which holds the AppKit-hosted suites, runs only in the guarded test runner). The app shell package moved to `macos/HfFeatures/Harflow`, and the app's Info.plist and icons to `macos/HarflowHost`. The built app is unchanged.

- A task's unsent message is kept when you switch to another screen and back (for example Task → Pending launches → Task). The text is restored exactly, including leading and trailing whitespace, and clears only when the view model accepts the send locally (an asynchronous refusal by the engine afterwards loses the text, as before). It survives a conversation being re-keyed when its earliest task ages out of the listing, continuation and parent links included, but never links tasks by `spawned_by`. If two conversations that each hold a different unsent message later join, one is shown (the one written for a task in the joined conversation, then the most recent) and the other is kept hidden for the rest of the session, never merged or deleted. Drafts live in app memory only: nothing is written to disk or sent to the engine, and Group, Parallel, workflow and New task composers are unchanged.

- Add Stop for pending launches, approved at HarflowDesign `83d820f`. Waiting, Preparing and Launch granted offer "Stop…" (only with a supported cancel mechanism and a known engine runtime) and a confirmation naming the full launch ID; Request Stop hands the command to the shared owner, which keeps it across navigation. Outcomes are shown as sending, "Stop was not sent. Try again.", "Stop requested", "Stop outcome unknown", "Stop refused" (with the engine's reason) and "Did not start" (only when the engine proves the launch never started). Acceptance is never shown as proof that anything stopped, a resolved Stop is never offered or sent again for the same launch generation, and nothing is retried automatically. The drawn workflow-specific "Stop refused" card waits for a stable engine reason code; every refusal uses the generic message meanwhile.

- Select HarflowMCP 0.0.13 as the paired managed runtime and vendor its contract bundle (334 fixtures, release commit `0ac7e3c`), replacing the provisional pending-launch bundle. The bundle supplies `task-pending-launch.v1`, so, once a 0.0.13 runtime is installed, the Pending launches screen no longer reaches its failed state for lack of the capability. The dependency set (29 wheels) and production export are unchanged from 0.0.12. Installation and runtime qualification of 0.0.13 are pending.

- Make pending launch rows selectable and add the selected launch's detail, approved at HarflowDesign `83d820f`. Nine states (waiting for resources, preparing, preparing with Stop unavailable, granted, did not start, status unavailable, not found, task record found, task status unavailable) show the qualified harness, repository, creation time and resources, or only the selected ID when nothing qualified was read, with a "Back to pending launches" button, "Check again" and the locked composer. A launch the engine now records as a task offers "Check task status", which opens the task only after the engine confirms its current status and retained history; a failed check leaves the detail in place. Nothing is shown from an earlier selection, and a result that arrives after Back, a runtime change or reselecting is ignored. The Stop button is not drawn yet. Also drop a released view's stored lookups in the shared owner, so repeated visits to the screen no longer fill its lookup bound.

- Add the "Pending launches" navigation item (clock icon, last in the sidebar and rail) and a read-only list of launches that have no task record yet, approved at HarflowDesign `83d820f`. The list shows checking, empty, failed, incomplete ("More launches may exist") and populated states over the shared pending-launch owner, with rows of title, harness, repository, state and full ID, a locked composer, and "Check again" (below the rows) for a full re-check. Selecting a row opens its detail (above); Stop and draft retention follow. The screen requires an engine advertising `task-pending-launch.v1`; an engine without it (0.0.12 and earlier) leaves the screen in its failed state.

- Add shared pending-launch read and Stop ownership, retaining uncertain outcomes across navigation and admitting recorded tasks only after fresh bounded ancestry reads. Native screen adoption follows separately.

- Add typed pending-launch inventory and exact-ID reads, plus capability-paired cancellation evidence. Native screen adoption follows separately; engine version pins are unchanged.

- Wire standalone Continue controls to shared attempt ownership, with accepted/pending and uncertain states, explicit successor checks, retained drafts and stale-target action guards.

- Retain Continue attempt outcomes across navigation and runtime selection, with explicit bounded successor checks and no automatic replay. Task-screen adoption remains deferred.

- Add a capability-gated Continue client with typed launch outcomes. Task-screen controls and reconciliation remain deferred.

- Show Status unavailable after a failed current-task read, with Retry read, retained content and draft, and status-dependent actions locked until recovery.

- Show a Settling notice only while current event and stored-change reads both support it, retaining the reported status and existing outcome warnings.

- Keep an acknowledged Stop request across task navigation and show Stopping only after a fresh status read still reports Running with an alive observer.

- Explain standalone task owner loss, unverified supervision and inferred outcomes using the reported snapshot, with existing Stop, Refresh, resume-copy and Events actions.

- Remove the standalone task’s duplicate header metadata, breadcrumbs and banners. Their actions and facts remain in the toolbar, More actions and Events; subtasks keep a compact provenance line, and action outcomes stay visible. Group and embedded headers are unchanged.

- Add the standalone task’s Stop confirmation sheet and composer Stop button. Both entry points share the captured current-run target; the sheet labels earlier-turn tasks outside the request and preserves the message draft when dismissed.

- Move the standalone task’s terminal action into More actions, with task ID, parent and repository shortcuts. Events stays in the right pane; Group and embedded controls are unchanged.

- Select HarflowMCP 0.0.12 as the paired managed runtime and vendor its contract bundle (320 fixtures). MonitorCore gains capability flags for the new engine features and decoders for artifact registration details and error reasons, continuation-stop status, cancel observations and the chain-stopped refusal, and gates the artifact read on `task-artifacts.v1`; no screen changes yet. Installation and runtime qualification of 0.0.12 are pending.

- Match the "Runtime ready" screen shown while the first task listing loads to the runtime setup screen, so the pane no longer shifts when setup finishes. It uses the same 26-point title and 14-point body, drops the spinner, and a failed listing shows its message as selectable text below the body with a small "Retry loading work" button.

- Match the first-run main pane to the approved runtime setup design: a 26-point title, 14-point body and status text in the primary colour, a small bordered action, and the body copy for each state. The spinner is gone for checking, installing and updating; installing and updating show "Installation in progress" or "Update in progress" instead, and a failure shows its message as selectable text below the body. The status line is announced to assistive technology when it changes to a non-empty value (not on first appearance).

- Remove the unused sidebar install-banner code and its view-model, repository and list-entry plumbing, and the unused setup-card spacing tokens and eyebrow and footnote text styles. No visible change; the menu bar and Settings keep their install notices.

- Replace the sidebar's runtime setup card with one line, "Runtime setup required before creating or loading work.", below the title row while the managed runtime is not ready. The sidebar no longer shows setup actions, the install notice, the backend-list note or the store-attention link in that state; setup actions are in the main pane and Settings → General. The ready sidebar also no longer shows the post-install success notice or the legacy install/update banner actions; the menu bar keeps its own notice. Store attention now sits below the title row in the ready sidebar, and a legacy list error is shown as plain text instead of being hidden when it is an install need.

- Remove the "Starting task…" progress row from the New Session composer. Start stays disabled and named "Starting task" while a task starts, and "Starting task…" is announced once to assistive technology; the space the row occupied is gone.

- Restore focus to the originating task-toolbar chip after its revealed pane closes. Deferred keyboard and accessibility focus respect the originating window, current pane request, user input and control visibility.

- Move the standalone task screen's title and status into the window's top bar. The title, a status badge (with the running clock, or the recorded duration of a settled task) and the backend, model, repository and turns now sit in the toolbar's centre; the badge says "Running · owner lost", "Running · not verified" or "Done · exit not observed" where the engine's evidence supports it, and "taken over" after the status. Observation resumed, notices and access are chips at the right of the bar that open the matching group in the right pane; they shrink to icons or counts below 1100 points. The whole backend, model, repository and turns line hides when the window is narrow, the task is pending, the pane is open with a notices or continuity chip, or the title needs the room. The task header no longer repeats the title. Group and the workflow builder are unchanged.

- Make the Changes tab's rows selectable. Choosing a row reads its stored diff and shows it under the list with added, removed and hunk lines, a path and scope header, a "Bytes, not UTF-8" label when needed and a note where the stored text ends. Rows with no stored text (binary, omitted, not captured) show their reason instead of reading anything. If the stored changes were replaced since the list loaded, the view says the diff could not be read and offers Reload changes. A conversation with follow-up turns gets a turn picker, newest first; the tab count follows the picked turn. The selected row is remembered per conversation. Diff text is never logged or saved.

- Add a Changes tab to the task screen's right pane. It lists the repository differences stored when a task settled, by repository, then Committed and Working tree, with per-scope counts, a tab count that is drawn only when every repository and scope is available and not limited, and a plain sentence for every reason the engine gives. Any terminal status (finished, failed or cancelled) opens on Changes; a running task opens on Events. Rows show their status, path, state and line counts and are not yet selectable; diff text and a turn picker are still to come. A settling capture is checked again with the pane open or closed, after 5 seconds and then every 15 for up to five minutes. Paths and repository names are shown with control, bidirectional and invalid bytes spelled out. Group and the workflow builder are unchanged.

- End a completed task's transcript with a Summary entry on the task screen. It shows the reported summary after the final turn once the event log is final and the history is complete, and is left out when it equals the agent's last message byte for byte. The Events tab's usage group then reads "Reported usage" and drops the headline and Result it would repeat. Group and the workflow builder are unchanged.

- Replace the task screen's always-visible right column with an adaptive right pane. It has Artifacts and Events tabs, opens from the toolbar button ("Show right pane"), sits beside the conversation when the window is at least 900 points wide and over it otherwise, and remembers whether it was open per conversation. Events now begins with collapsible Task, What was enforced, Notices and Continuity sections; the notices and continuity shortcuts in the task header open them. Group and the workflow builder are unchanged.

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
