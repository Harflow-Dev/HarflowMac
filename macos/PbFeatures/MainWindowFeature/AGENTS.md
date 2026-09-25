# MainWindowFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The main window's whole split view, including its own navigation view: Sidebar (task list,
search/backend filter, parallel runs, interactive sessions), New Session (start a headless task or an
interactive terminal), Parallel (one column per group member), TaskDetail (Timeline/Changes/Prompt/
Raw Events/Terminal tabs, the Inspector, the MessageBox), and Interactive (the embedded terminal for a
session started from the Monitor itself, not a polybridge task). `MainWindowCoordinator.start()`
returns `MainWindowNavigationView` — the `NavigationSplitView` moved here from the app target's
`MainView.swift` in Phase 4d part 2 — which is generic over the `MainWindowNavigationCoordinator`
protocol, never the concrete coordinator. `InteractiveView` constructs
`TaskDetail/Component/TerminalPaneView.swift` directly (same module) for its embedded terminal pane;
`MainWindowNavigationCoordinator` no longer exposes a standalone `buildTerminalPane` now that the app
target's old `InteractiveView` (its only external caller) is gone.

- Swift 6 language mode (tools 6.2 default).
- Depends on `PbUtilities`, `PbCommon`, `PbUI`, `MonitorCore`, `PbRepository`, and `PbTerminal`
  (needed for `TerminalSessionRegistry`/`TerminalSession`: Sidebar shows a terminal glyph for a
  task with a live embedded session and lists interactive sessions; New Session starts one;
  Interactive tails the registry directly for its own session).
- `MainWindowCoordinator.selection: MonitorDestination?` and `isNewSessionPresented: Bool` are the
  real navigation state — the single source of truth the settled plan's window seam formalises
  app-wide. `AppCoordinator` (the app target's real root coordinator, Phase 5) delegates
  `.task`/`.group`/`.interactive`/`.newSession` straight onto `MainWindowCoordinator.handle(path:)`
  for the URL/notification/Cmd-N paths it owns; there is no app-target `Selection` enum, no
  `AppModel`, and no mirroring layer at all (Phase 4d part 2 dropped the last of it; Phase 5 deleted
  `AppModel`/`TransitionalAppCoordinator` outright).
- `MainWindowCoordinator` also owns the "remove an ended interactive session unless it is selected"
  rule (`subscribeToEndedSessions()`, set up in `init`) — moved here from the app target's `AppModel`
  once `selection` lived on this coordinator instead of there. The registry only publishes when a
  session ends; it never reads the selection itself. Only `.interactive`-kind sessions are ever
  auto-removed this way — a take-over session's lifetime is `TakeoverService`'s concern.
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
  the result.
- `PbUI.TaskRowModel`/`TaskRow` gained Sidebar-only fields (indent, meta line, live session, running
  clock) in this dispatch, with defaults that keep `MenuBarFeature`'s existing rows byte-identical —
  see that file's header for why one component covers both screens' rows.
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
- TaskDetail's git generation guard and its 10 s running-only poll (decision 8) live in
  `TaskDetailVM+Changes.swift`, going through `TaskDetailUseCase.scheduleRepeating(every:execute:)`
  (a thin pass-through to `PbRepository.Scheduling`) rather than a real timer, so tests never sleep.
  `GitChangesRepository` itself stays stateless.
- `TerminalPaneView` observes its `TerminalSession` directly (`@ObservedObject`) and builds a fresh
  `TerminalPaneModel` per render via `TerminalPaneModel.build(from:)` rather than the VM holding a
  cached copy — the VM would otherwise need its own Combine subscription to the session's
  `@Published` fields purely to re-derive text the view can already read live. The reservation-text
  rule itself (`TerminalPaneModel.reservationText(kind:ended:attached:hasAttachError:)`) is a
  separate pure function taking primitives, because `TerminalSession.attached`/`.attachError`/
  `.ended` are `private(set)`/`internal(set)` outside `PbTerminal` and a test here cannot fabricate
  arbitrary session states.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `PbTestUtilities`. Re-stubbing the same Mockable member twice in
  one test is FIFO/unreliable — see `ParallelVMTests`'s `Box` note and
  `TaskDetailVMTests`'s `refreshSnapshotEffect`/`gitChangesEffect` boxes for the fix.
