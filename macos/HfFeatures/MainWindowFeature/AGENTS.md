# MainWindowFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The main window's whole split view, including its own navigation view: Sidebar (task list,
search/backend filter, parallel runs), New Session (start a headless task), Parallel (one column per
group member), and TaskDetail (the Activity feed, the Events and Summary content, the Inspector, the
MessageBox). `MainWindowCoordinator.start()` returns `MainWindowNavigationView` — the
`NavigationSplitView` is generic over the `MainWindowNavigationCoordinator` protocol, never the concrete coordinator. There is
no embedded terminal anywhere in this package:
"Take over" opens the regular macOS Terminal.app instead, through `HfRepository.TakeoverService`.

- Swift 6 language mode (tools 6.2 default).
- Depends on `HfUtilities`, `HfCommon`, `HfUI`, `MonitorCore`, and `HfRepository`.
- `MainWindowCoordinator.selection: MonitorDestination?` and `presentedSheet: MainWindowSheet?`
  own selection and mutually exclusive modal state app-wide. `isNewSessionPresented` and
  `isWorkflowRunnerPresented` are compatibility projections; dismissing either clears only its
  matching active destination. Lightweight preview/test coordinators may derive `presentedSheet`
  through the protocol fallback rather than storing it. `AppCoordinator` (the app target's real root
  coordinator) delegates
  `.task`/`.group`/`.newSession` straight onto `MainWindowCoordinator.handle(path:)` for the
  URL/notification/Cmd-N paths it owns; there is no app-target `Selection` enum, no `AppModel`, and no
  mirroring layer.
- `HfUI.withPresentationContext()` is applied exactly **once**, at `MainWindowNavigationView`'s own
  root. Every screen under the navigation view, including the New Session sheet, shares that
  one `@Environment(\.viewEvent)` through the presenting view's environment.
- `SidebarRouting` doubles as the read side of that same selection state (`selection`/
  `selectionPublisher()`) so the Sidebar's `List(selection:)` binding reflects a selection made
  elsewhere (e.g. "Open parent" or a breadcrumb tap in `TaskDetail`), not just its own taps.
- The New Session directory chooser is presented by `MainWindowCoordinator.chooseDirectory()`
  (`NSOpenPanel`, AppKit) — never the VM, which only calls `routing.chooseDirectory()` and awaits
  the result. New Session is headless-only: a non-blank message is required to start.
- `HfUI.TaskRowModel`/`TaskRow` gained Sidebar-only fields (indent, meta line, running clock) in an
  earlier dispatch, with defaults that keep `MenuBarFeature`'s existing rows byte-identical — see that
  file's header for why one component covers both screens' rows.
- **Collapsible task tree.** `TaskRowModel` gained three more Sidebar-only fields —
  `hasChildren`, `isExpanded`, `guides: [MonitorCore.TreeGuide]` — again defaulted to keep MenuBar's
  rows byte-identical. `TaskNode.flattenedWithGuides()` (`MonitorCore/Lineage.swift`) is the pure
  guide computation; `SidebarVM` owns the collapsed-task-id set (expanded by default, lives for the
  app's lifetime), `didToggleExpansion(taskID:)`, and the ←/→ keyboard handler
  (`didPressMoveCommand(_:)`, attached to the sidebar `List` via `.onMoveCommand`, never the window).
  A collapsed parent's meta line becomes the subtree summary ("N sub-tasks, M running"); an active
  search/backend filter force-expands the ancestors of an actual match **for display only** — it
  never mutates the collapsed set, so clearing the filter restores exactly what was collapsed.
  **The pending reveal is coordinator-owned, not VM-owned**, precisely because
  `MainWindowCoordinator.selection`'s own `didSet` drops a repeated assignment (see its doc comment):
  `handle(path:)`'s `.task` case and the shared `ParallelRouting`/`TaskDetailRouting.selectTask(_:)`
  both call a private `requestReveal(taskID:)` that stamps a fresh `PendingReveal(taskID:requestID:)`
  every time, repeats included, and fires it through `SidebarRouting.revealPublisher()`; the sidebar's
  own click (`SidebarRouting.select(_:)`) deliberately does not. `SidebarVM` expands the revealed
  task's ancestors and consumes it via `consumeReveal(requestID:)` — once; a reveal for a task not
  yet in the listing stays pending and retries on every subsequent listing; `didAppear()` also checks
  `routing.pendingReveal` directly, so a reveal requested while the sidebar was unsubscribed (window
  closed) is not lost.
- `Component/TimelineRow.swift` and `Component/ToolRow.swift` (root-level, not under `Parallel/`) are
  shared Model+View pairs Parallel and TaskDetail's own `TimelinePaneView` both use.
- **Transcript style.** `ActivityFeedStyle` (`TaskDetail/Activity/ActivityFeedStyle.swift`) is `.standard`
  (default everywhere, unchanged) or `.transcript` (`TaskScreenStyle` metrics: 760 column, 32 point
  side padding, 16 point row gap, user bubble, prose, tool head/body, working row, turn separator,
  the `--bg` pane background). It travels `TaskDetailView(transcriptStyle:)` → `TimelinePaneView(style:)`
  → `ActivityFeedView(style:)` → `ActivityFeedNativeModel.style` and reaches row views through the
  `activityFeedStyle` environment value set by the row root, so measurement and display agree. A style
  change is part of the feed's root-inputs key and remeasures through the structural route. On for the
  standalone task (`MainWindowCoordinator.buildTaskDetailView`) and Group
  (`GroupPresentationView`) mounts; off for the builder mount (`isEmbedded`), Parallel columns and
  workflow surfaces. Tool bodies are unbounded in height (no 220 point cap): a recorded deviation pending owner review.
  `MessageBoxStyle` follows the same mounts through `TaskDetailView`: `.transcript` is the solid
  `.hd-composer` surface, `.standard` keeps glass for Parallel and workflow composers. Field and actions stay
  in one row with the printed hint; the stacked form and an editor swap wait on a design for Send now and locked states.
- **Summary entry.** The standalone transcript (`TaskDetailChrome.standalone` only, copied into
  `TaskDetailTimelineInput.showsSummaryEntry` from the VM's explicit `chrome:` init parameter) can end with
  `ActivityRow.summary(SummaryEntry)`: the "Summary" divider (the shared `TurnSeparatorDivider`, an accessibility
  heading) and the reported summary as agent prose a transcript row gap below it, as the last row, before
  approvals, the tail and the bottom sentinel. `TaskDetailSummaryEntryRule.decide` runs in
  `TaskDetailTimelineBuilder.build`, off the main actor. Every build requires a completed task and snapshot of the
  conversation's last member, a non-blank `TaskReportedSummary` projection (the one projection `recomputeSummary`
  shares), no managed-workflow result error and `logState == .final`. A decision already made for the same member,
  raw summary and observation source (`EventObservationFrame.scope`, which a source adoption or window reset
  changes) is kept as is, whatever the currentness or drain state, and is never deduplicated again. Establishing a
  new decision also needs `forwardDrained`, `caughtUp` and `currentness == .current`, none of the evidence-loss
  reasons, text evidence (no text item with `hasOlder` waits for paging), and the entry is suppressed only when the
  raw summary equals, byte for byte, the member's last `.text` item of any kind; a streaming last text never
  suppresses. `summaryEntryShown` is part of the timeline presentation, written to the VM only on change, and makes
  the Events usage group drop the hero and Result.
- **Standalone right pane.** `TaskDetailView(chrome:)` takes `.standalone` (the window's task selection, built by
  `MainWindowCoordinator.buildTaskDetailView`), `.group` (the default; Group's task pane) or `.embedded` (the
  workflow builder row). Only `.standalone` gets the adaptive 420 point pane; `.group` and `.embedded` keep the
  always-mounted legacy pane (320 and 280 points) with `eventsExpanded`, and never build the pane controller or
  store (`TaskPaneHolder` creates them on first use). The pane is mounted only while open and has tabs `Changes`,
  `Artifacts` and `Events`. Logic lives in `TaskPaneController`: a
  flexible clear layer measures the container that holds the column and the pane, and both are drawn over it, so
  the measured width never depends on the pane mode. The width itself is unobserved; only the derived `mode` is
  observed and written when it changes, so a live resize does not re-evaluate the view per frame. At 900 points
  and above the pane is split (the column reserves 420 points of trailing padding); below, it overlays the column
  with the popover shadow and a 1 point outer ring and the transcript width is unchanged. The pane is one view in
  both modes (only padding, shadow and ring ink change), so crossing the threshold never remounts it.
  Choices persist in `MainWindowCoordinator.paneState` (`TaskPaneStateStore`, keyed by conversation id, because
  `.id(conversationID)` destroys view state): open or closed, the person's selected tab (`nil` until they choose),
  expanded facts groups, the applied default (open and tab), whether Technical info is expanded, and (in a separate bounded, unobserved dictionary that never creates
  or evicts an entry) the Events scroll offset, so a close, tab switch or split/overlay crossing restores the
  reading position against the same document height. The default tab is resolved with the open default, once: `Changes` for a terminal status, `Events` for running,
  pending or any other status, and `Events` is shown before the default is ready; a pane already shown on that fallback
  keeps it as its default so it never jumps, and a person's selection wins from then on (`revealFacts` still forces
  Events). The default is resolved once, on first show, and stored: a
  conversation first shown running (or taken over, or failed) stays closed when revisited after it finishes, until
  the person chooses. Only a done task whose own snapshot observed an exit is open by default, and only while the
  container is at split width (below 900 it closes again); a person's own open or closed choice wins through any
  width change. `TaskSnapshotEvidence` (fed from the VM's shown task, its matching snapshot and the observation
  frame's `logState`) is the pure source of the default and the exit row: a real exit code is always shown;
  "Not observed" only for done with no exit, and failed with no exit when `log.state` is `incomplete`; every other
  terminal status without an exit shows a dash. The Events tab shows facts groups (Task, What was enforced,
  Notices, Continuity when shown, and the usage group holding `SummaryPaneView`: "Reported result and usage", or
  "Reported usage" without the hero and Result while the transcript's Summary entry shows), collapsed unless revealed, then `PublicEventsView` unchanged. `revealFacts(group:origin:)` opens
  the pane, selects Events, expands the group and moves keyboard focus and the VoiceOver cursor into it. Escape
  (handled by `PaneEscapeMonitor`, a window-scoped local key monitor that works with no focused
  descendant, acts only when focus is nowhere, inside the task detail region, or in the current visible
  reveal-origin toolbar chip, and passes Escape through to a field
  editor, a sheet, another window, another region such as the sidebar, or a Command/Option/Control/Shift key;
  a declined result must be side-effect free. Escape typed in the composer passes through and does not close the
  overlay, a deliberate deviation; any in-window dialog added later must be excluded from this monitor) leaves a
  focused group, then closes an overlay, then closes a pane a reveal opened; every close of a revealed pane
  (Escape, the close button, the toolbar toggle) returns focus and the VoiceOver cursor to the originating control that
  revealed it. Closing, opening and tab selection clear any pending focus request, and person-driven changes run
  through `pane.animated`. The overlay pane carries the modal accessibility trait. The window toolbar's inspector
  item keeps its identifier and reads "Show right pane"/"Hide right pane" on the standalone mount only (Group keeps
  "Show/Hide event details"); its snapshot carries the open state and that label choice, so the equality boundary
  is unchanged.
- **Task top bar (standalone mount, M05 stage D1).** The shell's single `.principal` toolbar item draws
  `TaskTopBarPrincipal`: the title, status badge (`TaskBadgeModel`/`TaskStatusBadge`), a fixed busy slot, meta and the
  connection status, laid out inside a width cap by the pure solver `TopBarPrincipalLayout.solve` (the toolbar never
  truncates a principal item; it overflows the other items). Every other selection, and a task before it publishes,
  keeps the shell's `contextTitle`. Content travels through `TaskTopBarHolder` (owned by the coordinator, exposed as
  `topBar`): a standalone `TaskDetailVM` publishes a quantised `TaskTopBarContent` through `TaskDetailRouting`
  (`publishTopBar`/`clearTopBar`/`activateTopBar`/`deactivateTopBar`/`retryTopBarActivation`; a publish retries activation only when no other writer holds the bar), writing only on change, on every `didAppear`
  and clearing on `didDisappear` and `resetForMissingTask`. The holder shows only the entry of its `activeTag`, and only
  while that tag's conversation equals `shownConversation`, which the coordinator sets from `selection` (never from a
  view body) with the same normalisation as `buildTaskDetailView`; a change drops the active tag, so one task's content
  never flashes over another's. A listing change refreshes `shownConversation` only while no tag is active. The shell
  measures the window into a `TopBarWidthBand` (under 1100, 1100, 1280, 1600) and writes it into `TopBarLayoutState`
  only when it changes, never reading it, so it does not re-evaluate on a crossing; the band gives the cap (read by the
  principal) and an observed `isNarrow` (read through the `topBarLayout` environment value by the task view's chips,
  which re-evaluate only when it flips). Group and embedded keep the `task-detail.status` item,
  the full header and `contextTitle`. The standalone toolbar's chips (`task-detail.chip.continuity`, `.notices`,
  `.access`) are separate trailing items that appear only while their condition holds; they reveal the matching facts
  group and return focus to the chip where AppKit accepts it. The badge is derived only from `TaskSnapshotEvidence`
  (`ownerState`, `settledDuration` and the exit come from the matching snapshot); HfUI `StatusBadge` is unchanged. On
  the standalone mount the legacy header is absent: the toolbar, its chips and More actions own its former
  metadata and shortcuts. Only a present outcome keeps a compact feedback row. The short subtask provenance
  line follows Original request, while Events Task facts preserve the full first-member routing sentence and
  takeover note (including the prior banner fallback). Group/embedded retain the legacy header and controls.
  No explicit toolbar id may be reused or duplicated.
- **Standalone state treatments.** `TaskStateTreatment` requires status-matching snapshot evidence
  and suppresses all treatments for taken-over tasks. Only running + owner `dead` claims capture
  loss; `undecidable` keeps uncertainty. Completed without an exit is reconstructed; failed
  without an exit also requires an incomplete log. The native feed receives an optional value
  (included in model equality): notices before activity, banners after activity and the live
  tail, with stable per-task identity and latest action callbacks. Other mounts pass `nil`.
  Stop uses the existing confirmation; Refresh reads the member captured at invocation; Open
  Events uses ordinary pane selection. The disabled Continue is presentation only. Stopping is
  queried from the shared action repository on mount/invalidation, gated again on matching current
  Running/alive-owner evidence. It keeps the Running badge, adds the leading info notice and
  disables the transcript Stopping… action without touching the draft or send behavior. VM
  disappearance does not clear the repository request. Settling, status-unavailable and Continue
  launch need their separate evidence/action stages.
- **Conversations.** A follow-up sent to a finished task continues the same
  conversation, never a new sidebar row: `Lineage.conversations(_:)`/`conversationSections(_:matches:)`
  (`MonitorCore/Conversation.swift`) group tasks by `parent_task_id` (a resume chain — distinct from
  `spawned_by`, "who called `start_task`") into a `Conversation`/`ConversationNode` tree, built and
  guarded the same way `TaskNode`/`Lineage.sections(_:matches:)` are (shared guide computation via
  `TreeGuides`) — Parallel groups stay on the task-level `Lineage.sections(_:).parallel`, unaffected.
  `SidebarVM`'s rows, collapse set and reveal all key off the conversation id (its first, earliest
  member); any member id a selection carries (a URL, notification, breadcrumb, or Parallel "open
  task") is normalised to that id via `Lineage.conversationID(of:in:)` before it reaches the row
  binding or the reveal/ancestor walk. `TaskDetailVM` resolves the whole conversation from whatever
  member id it was built with (`TaskDetailUseCase.conversationMembers(of:)`), holds one
  `EventStreamRepository` lease per member (Parallel's own pattern), and every derived property
  reflects the **current** (newest) member except title/breadcrumbs/lineage, which come from the
  **first**. The Timeline concatenates each member's own paired events
  (`MonitorCore.ConversationTimeline.rows(members:)` — pairing stays scoped per member, since call
  ids and `seq` both restart per task) with a turn separator ahead of every follow-up; a row's `live`
  flag is per-turn, so an unresolved tool call in an older, already-terminal turn never shows a
  spinner even while the newest turn runs. The summary's "Files edited" merges each
  member's `observationFrames[_].summary` projection, and the VM derives availability from those
  frames, rather than reading one task's stream. Every action (send/cancel/take over/copy resume command/continue)
  targets the conversation's current member (`TaskDetailVM.currentTaskID`), never the VM's own fixed
  `taskID`. Continue (`submitMessage`'s resume branch) no longer navigates on success — the
  conversation stays selected, and the new turn appears once `tasksPublisher` picks up the new member
  — so `TaskActionRepository.resume`'s `onResumed` closure is a no-op from this call site now.
  **Cancel scope honesty:** the cancel confirmation
  (`TaskDetailVM+Actions.swift`'s `didTapCancel()`) describes the REAL scope of cancelling the
  current task — `TaskDetailUseCase.cancelScope(of:)` (`MonitorCore.Lineage.cancelScope(of:in:)`,
  which matches `tasks.py`'s cascade exactly: `spawned_by` descendants plus any task whose
  `root_task_id` names it) — and names any still-running child an EARLIER turn started that this
  scope does not reach ("Still running from earlier turns (not cancelled by this): …"), computed by
  `allConversationChildren()` (children of every member) filtered against that scope.
  **Retention while open:** `TaskDetailVM`
  remembers `lastKnownMemberIDsOldestFirst` from every successful direct resolution; when its own
  `taskID` stops resolving (its record was pruned), it retries through the oldest still-present
  remembered member instead of reporting the conversation gone. `SidebarVM` keeps the analogous
  `lastKnownSiblingsByMember` map (`SidebarVM+Retention.swift`) — a plain `[memberID: Set<memberID>]`
  snapshot of each conversation's membership, not a persistent union-find — so `normalized(_:)` can
  resolve a since-pruned id through a surviving sibling, `recompute()` re-normalises the CURRENT
  selection every pass (so the highlighted row follows a conversation whose id just shifted with no
  new selection event), and `migrateCollapsedIDsForRetention()` carries a collapsed entry from an
  old id to its conversation's new one.
- Parallel keeps complete group membership for summaries and actions, but acquires activity leases
  only for members of viewport-intersecting conversations; do not prefetch neighboring columns.
  The standalone group and workflow Parallel view share the measured horizontal viewport surface.
  The Graph selected-node inspector instead renders one width-fitting conversation at a time; its
  explicit selector determines residency while its measured width is positive. Zero width or hiding
  releases its leases. Keep selection and visited reading state across switches and suspension; new
  arrivals and reordering preserve a valid manual selection. Lazy view appearance is not visibility evidence. Never-visited conversations keep lightweight descriptors.
  Leaving the viewport releases only this VM's leases and subscriptions and stops activity updates,
  while retaining the visited conversation's loaded presentation, history boundaries, scroll anchor,
  disclosure and live-follow state until removal or full teardown. Reentry displays the snapshot
  immediately and refreshes it in the background. Memory grows with visited conversations and
  requested history; only active lease/update work is bounded by the visible viewport. Teardown
  clears retained snapshots and all remaining work. Build immutable presentation values off the main
  actor and publish only complete values that changed.
- Task-detail and both Parallel activity surfaces share automatic older-history pagination.
  Initialize at latest activity; load near the oldest visible edge only after positioning settles.
  Reveal retained rows in batches of 100 before reading another bounded event page. Only visible
  Parallel columns initiate pagination and hold activity leases. Preserve logical reading anchors
  through prepends and regrouping, and keep live-follow paused while reading or restoring.
  Bound automatic short-feed filling so collapsed groups cannot drain history on mount; renewed
  upward scrolling or disclosure interaction permits more. Monitor scroll intent only for visible feeds.
  Page loading ends after the corresponding item snapshot commits, never before background folding.
  **Structural fallback.** When a structural reload removes the captured reading row, `ActivityFeedNativeReading.structuralFallback`
  picks, in order, the first visible surviving row (held at its old on-screen offset), the first visible surviving tail or
  approval, then the nearest preceding surviving row (else the nearest following one) with its offset recomputed; the
  preceding row applies only when nothing visible survives, such as a removed entry taller than the viewport. The scope is
  the removed-anchor fallback: when `transferRegroupedState` hands the persisted anchor to a replacement that shares
  members with the old row, the persisted-anchor branch of `structuralReading` pins that replacement (the logical anchor)
  before the fallback runs, and that is unchanged. The tail insert keeps its own `survivingReading`.
- `.id(name)` for `buildParallelView(name:)`'s per-group VM reset is applied at that call site,
  wrapping the whole `ParallelView(vm)` value — never inside `ParallelView.body`. `ParallelView` owns
  `@State var viewModel: VM`, and that state is tied to the view's own identity as seen by its
  *caller*; an `.id()` inside `body` only re-identifies that body's descendants, never the enclosing
  `@State`.
  Any future coordinator-built VM keyed by an identifier must follow the same placement.
- `.id(id)` for `buildTaskDetailView(id:)`'s per-task VM reset follows the exact same rule as
  `buildParallelView(name:)` above: applied at the coordinator call site, wrapping the whole
  `TaskDetailView(vm)` value — never inside `TaskDetailView.body`.
- TaskDetail's summary model replaced the git-backed
  Changes tab outright — no git guard and no git poll. The standalone Changes tab instead presents the engine's stored
  `task-changes.v1` listing (`TaskDetail/Changes/`, `TaskDetailVM+Changes.swift`), and `TaskDetailVM` takes an explicit
  `scheduler: Scheduling` at every construction site, used only for the bounded settling cadence below.
  **Changes reads.** Only the standalone chrome reads, and only between `didAppear` and `didDisappear`. Demand is the
  pane being open (reported by the view through `setPaneOpen`), or a settling condition (a terminal status whose
  `logState` is `.settling`, or the last applied result being `pending/capture_settling`), which works with the pane
  closed. A read starts only with demand, once per epoch (the member, a shown-status transition, a changed member set, Retry); transitions
  without demand only mark the result stale, and reopening the pane does not re-read. Every read gets a new generation;
  the repository's `@Sendable` fence reads it from a lock (`TaskChangesFence`), and the main actor checks it again before
  applying. The presentation is built off the main actor by the pure `TaskChangesPresentationBuilder` and applied only
  when it differs; the tab count (`changesTabCount`) is a separately observed field drawn only from an applied result.
  The cadence (5 s after the first settling result, then 15 s, scheduled from the applied result so reads never overlap,
  capped at 5 minutes of continuous settling, then "Check again") only repeats a presentation read. A runtime change that
  supersedes a read is read once more, and the "does not support Changes" state offers Retry instead of clearing on its
  own. Diff and file text never reach logs, descriptions or persistence. `TaskChangesDisplayText.escaped` spells out
  invalid bytes, controls, bidi controls, `Cf` characters and backslashes in every path, name and provenance value.
  **Changes text and turns.** Rows with a selector are buttons (`didSelectChangesRow`); a row no selector can address is dimmed
  and disabled. A selected row's patch (`TaskDetailVM+ChangesText.swift`) is bound to (member task id, listing revision,
  patch generation, selector) and applies only while all four match; a turn change, a replaced listing (changed row facts),
  `didDisappear` and `resetForMissingTask` invalidate it. Rows whose content is not `available` or `truncated` select without
  reading and show their label. The selection (member task id plus the row's `TaskChangesSelector`, never text) is
  remembered in `TaskPaneStateStore` and handed back through `restoreChangesSelection`; it is matched against the loaded
  listing of its member and dropped silently when the row is absent, and a note or loading listing neither confirms nor drops
  it. `UnifiedDiffLines.classify` is hunk-aware: outside a hunk lines are meta, inside the first character decides, and a line
  that fits neither starts the next section. `changes_entry_not_found` and `changes_cursor_expired` drop the selection, read the
  listing again and show "This diff couldn't be read" with Reload changes; a client-bound or other failure offers Retry. The
  turn picker (several members only) lists newest first, defaults to the current member and resets to it when a new member
  appears or the picked one is pruned; "Turn N of M" is index-based, so it renumbers after pruning. Every applied listing
  carries a fingerprint (per row status, counts, content and selector; per repository base, head, observation time and state;
  per scope state and row count): a changed fingerprint replaces the listing and invalidates the patch, an identical one keeps
  it. The diff is one read-only, selectable TextKit 1 text view (`NSViewRepresentable`) over an `NSAttributedString` built off the
  main actor from the classified lines (`TaskChangesDiffText`); only the lines in view are laid out and drawn, with full-width
  fills for added, removed and hunk lines, a capped height with its own scrolling and sideways scrolling instead of wrapping.
  Accessibility: the text view is labelled "Diff of <path>" and added, removed and context lines start with `+`, `-` or a space in
  the text itself, so the convention is the line prefix. Lines split on LF and classify on the first Unicode scalar; a trailing CR is
  dropped from each line and "Lines end in CRLF" is noted once beside the header. Bidi controls, other `Cf` characters,
  C1 controls, DEL and C0 controls except tab are drawn escaped (`TaskChangesDisplayText.diffSafe`); other text is unchanged.
  Diff equality compares an identity hashed from the patch bytes, never the lines. A superseded patch read is repeated once while its
  fence is current. Only a "Reload changes" failure survives a dropped selection, and the replacement listing clears it. Diff types
  describe themselves without their text.
  `TaskDetailVM+Summary.swift` rebuilds `SummaryPaneModel` synchronously on every `recompute()`
  from the task's own reported fields (`TaskInfo.summary`/`notices`/`permissionDenials`/
  `enforcement`/`totalCostUSD`/`numTurns`/`raw["usage"]`) and the observed activity summaries — "Files edited"
  merges each conversation member's already-paired projection
  (`observationFrames[_].summary`), never git. `TaskDetailUseCase.eventsAvailability(for:)`/`eventsAvailabilityPublisher(for:)`
  (backed by `EventStreamRepository`) carry the tailer's `loading`/`available`/`unavailable` state
  so an empty edit list is never confused with "the log couldn't be read".
- Take over (`TaskDetailVM+Actions.swift`'s `didTapTakeover()`, `ParallelVM`'s `didTapTakeover(taskID:)`)
  is an entry in the standalone task overflow, and a plain button in Group, embedded and Parallel
  views. There is exactly one destination. The confirmation dialog says the
  session opens in Terminal.app; the actual hand-off (`ctl takeover` grant → hand-off files →
  `open -a Terminal`) lives entirely in `HfRepository.TakeoverServiceImpl`, which this package only
  calls through `TaskDetailUseCase.beginTakeover(taskID:)`/`ParallelUseCase.beginTakeover(taskID:)`.
- Standalone task Stop uses the coordinator-owned `.stopTask` sheet, shared by the overflow and
  transcript composer. Its request captures the current run and client-derived earlier-turn
  exclusions. Confirm consumes only the active request once, then checks the captured current
  member before cancelling. Dismissal, a different conversation, runtime loss or modal replacement
  clears the request. Native sheet modality owns Escape; the right-pane monitor must leave it
  alone. The composer offers Stop only on an eligible standalone task that is not taken over,
  independently of a message draft, and disables it while busy. Group, embedded and Parallel retain
  their legacy dialogs.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `HfTestUtilities`. Re-stubbing the same Mockable member twice in
  one test is FIFO/unreliable — see `ParallelVMTests`'s `Box` note and
  `TaskDetailVMTests`'s `refreshSnapshotEffect` box for the fix.
