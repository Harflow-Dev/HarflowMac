# MainWindowFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The main window's whole split view, including its own navigation view: Sidebar (task list,
search/backend filter, parallel runs), New Session (start a headless task), Parallel (one column per
group member), and TaskDetail (Timeline/Summary/Prompt/Raw Events tabs, the Inspector, the
MessageBox). `MainWindowCoordinator.start()` returns `MainWindowNavigationView` — the
`NavigationSplitView` moved here from the app target's `MainView.swift` in Phase 4d part 2 — which is
generic over the `MainWindowNavigationCoordinator` protocol, never the concrete coordinator. There is
no embedded terminal anywhere in this package (piece 1 of the Monitor architecture plan removed it):
"Take over" opens the regular macOS Terminal.app instead, through `PbRepository.TakeoverService`.

- Swift 6 language mode (tools 6.2 default).
- Depends on `PbUtilities`, `PbCommon`, `PbUI`, `MonitorCore`, and `PbRepository`.
- `MainWindowCoordinator.selection: MonitorDestination?` and `isNewSessionPresented: Bool` are the
  real navigation state — the single source of truth the settled plan's window seam formalises
  app-wide. `AppCoordinator` (the app target's real root coordinator, Phase 5) delegates
  `.task`/`.group`/`.newSession` straight onto `MainWindowCoordinator.handle(path:)` for the
  URL/notification/Cmd-N paths it owns; there is no app-target `Selection` enum, no `AppModel`, and no
  mirroring layer at all (Phase 4d part 2 dropped the last of it; Phase 5 deleted
  `AppModel`/`TransitionalAppCoordinator` outright).
- `PbUI.withPresentationContext()` is applied exactly **once**, at `MainWindowNavigationView`'s own
  root (Phase 4d part 2) — not per screen any more. `buildParallelView(name:)`/`buildTaskDetailView(id:)`
  used to apply it themselves in earlier phases (before this package owned a navigation view of its
  own); every screen under the navigation view — including the New Session sheet, which SwiftUI
  carries the presenting view's environment into — now shares that one `@Environment(\.viewEvent)`.
- `SidebarRouting` doubles as the read side of that same selection state (`selection`/
  `selectionPublisher()`) so the Sidebar's `List(selection:)` binding reflects a selection made
  elsewhere (e.g. "Open parent" or a breadcrumb tap in `TaskDetail`), not just its own taps.
- The New Session directory chooser is presented by `MainWindowCoordinator.chooseDirectory()`
  (`NSOpenPanel`, AppKit) — never the VM, which only calls `routing.chooseDirectory()` and awaits
  the result. New Session is headless-only: a non-blank message is required to start.
- `PbUI.TaskRowModel`/`TaskRow` gained Sidebar-only fields (indent, meta line, running clock) in an
  earlier dispatch, with defaults that keep `MenuBarFeature`'s existing rows byte-identical — see that
  file's header for why one component covers both screens' rows.
- **Collapsible task tree (Monitor piece 4).** `TaskRowModel` gained three more Sidebar-only fields —
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
- Parallel acquires one `EventStreamRepository` lease per group member in `didAppear`/on membership
  change, and releases every lease in `didDisappear` — the one screen in this package with more than
  one concurrent lease per VM instance.
- `.id(name)` for `buildParallelView(name:)`'s per-group VM reset is applied at that call site,
  wrapping the whole `ParallelView(vm)` value — never inside `ParallelView.body`. `ParallelView` owns
  `@State var viewModel: VM`, and that state is tied to the view's own identity as seen by its
  *caller*; an `.id()` inside `body` only re-identifies that body's descendants, never the enclosing
  `@State` (a real bug caught in Phase 4c's Codex review — see the phase-4 brief's Lessons section).
  Any future coordinator-built VM keyed by an identifier must follow the same placement.
- `.id(id)` for `buildTaskDetailView(id:)`'s per-task VM reset follows the exact same rule as
  `buildParallelView(name:)` above: applied at the coordinator call site, wrapping the whole
  `TaskDetailView(vm)` value — never inside `TaskDetailView.body`.
- TaskDetail's Summary tab (piece 2/3 of the Monitor architecture plan) replaced the git-backed
  Changes tab outright — no git guard, no poll, no `Scheduling` dependency in this package any more.
  `TaskDetailVM+Summary.swift` rebuilds `SummaryPaneModel` synchronously on every `recompute()`
  from the task's own reported fields (`TaskInfo.summary`/`notices`/`permissionDenials`/
  `enforcement`/`totalCostUSD`/`numTurns`/`raw["usage"]`) and its raw event stream — "Files the
  agent edited" pairs `tool_call`/`tool_result` events by `call_id` (`MonitorCore.EditedFiles`),
  never git. `TaskDetailUseCase.eventsAvailability(for:)`/`eventsAvailabilityPublisher(for:)`
  (backed by `EventStreamRepository`) carry the tailer's `loading`/`available`/`unavailable` state
  so an empty edit list is never confused with "the log couldn't be read".
- Take over (`TaskDetailVM+Actions.swift`'s `didTapTakeover()`, `ParallelVM`'s `didTapTakeover(taskID:)`)
  is a plain button, never a menu — there is exactly one destination. The confirmation dialog says the
  session opens in Terminal.app; the actual hand-off (`ctl takeover` grant → hand-off files →
  `open -a Terminal`) lives entirely in `PbRepository.TakeoverServiceImpl`, which this package only
  calls through `TaskDetailUseCase.beginTakeover(taskID:)`/`ParallelUseCase.beginTakeover(taskID:)`.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `PbTestUtilities`. Re-stubbing the same Mockable member twice in
  one test is FIFO/unreliable — see `ParallelVMTests`'s `Box` note and
  `TaskDetailVMTests`'s `refreshSnapshotEffect` box for the fix.
