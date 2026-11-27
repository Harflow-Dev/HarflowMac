# MenuBarFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The status-bar item: `MenuBarLabel` (icon + running count, always alive) and the popover content
(`MenuBarView`), both driven by one shared `MenuBarVM` built by `MenuBarCoordinator`.

- Swift 6 language mode (tools 6.2 default).
- Depends on `HfUtilities`, `HfCommon`, `HfUI`, `MonitorCore`, `HfRepository`.
- Running rows tail their task's events via `EventStreamRepository` leases, acquired per row on
  appear and released on disappear (or when the VM itself tears down) — never in `init`.
- Roots come before sub-tasks; at most 3 recent groups and 6 recent roots. Ordering *within* the
  roots/sub-tasks groups is existing, undefined behaviour — do not add a stabilising sort.
- The window opener is captured once, in `MenuBarLabelView.onAppear`, and registered through the
  new `HfCommon.WindowPresenting` seam (see that file's header for why it was added here) rather
  than reaching into the app target directly — features never import the app target.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `HfTestUtilities`.

The popover follows the managed runtime (HarflowDesign `8ec4d38`, `menu-bar/runtime-*`, `engine-call-failed`). `MenuBarUseCase` exposes `runtimeSetupState` and a separate `workAvailable` (the runtime is ready and `MainWindowGate.classify` finds no gate, computed in `MenuBarViewRepository.workAvailability`); `canStartNewSession` follows `workAvailable`, never the setup state alone. `MenuBarRuntimeCard` (own file and view) replaces the sections while the runtime is not ready, with Open Harflow for setup-required and failed and no spinner, and the header's connection dot and subline row are hidden meanwhile. `MenuBarRefreshNote` is the ready-runtime listing failure: the `LoadingWorkError` sentence only, no Code line (like the sidebar's note), above the rows, with Retry calling `refreshWork()`; a managed-runtime-unavailable listing error shows no note. There is no install success notice and no install banner.

A plain Needs you question (`kind == .question`, no offered answers) is a `MenuBarQuestionCard` on `MenuBarNeedsYouSection.Row.question`; approvals, recoveries and questions with offered answers keep the Answer button that opens the item. `MenuBarVM+Questions.swift` holds the draft per item id (kept across popover close, dropped when the item leaves the snapshot), the phase mapping (`phase(for:item:draft:)`, pure) and the held cards: settled and unknown cards stay per item id until `didPopoverClose()` and render even when `settle` already removed the item from the snapshot. `NeedsYouAnswerOutcome.unknown` (timeout or no answer) disables the field, offers Open Needs you and is never resent automatically (it resets on popover close, after which the person can answer again); a failure shows its message and a `DetailLine("Code")`. A submit that finishes after the popover has closed is held until the next close. Return in the field submits.

Workflow rows read `created_at` (epoch seconds, the sidebar's source) into `WorkflowMenuBarRow.startedAt`. `WorkflowMenuBarRowView.trailing(for:)` shows the elapsed clock for a row whose status is exactly "running" and that has a start (as the sidebar does), and the status label otherwise; a time is never invented. The status item's VoiceOver value is `MenuBarLabelAccessibility.accessibilityValue`, which reads the runtime card's subline while a card shows. The "Workflows" label above the status-unavailable line appears only when no run rows are listed.
- The popover's running spinners are HfUI's Core Animation `RunningSpinner` (no SwiftUI per-frame clock). Its 1 Hz elapsed clocks (`MenuBarRunningRowView`, `WorkflowMenuBarRowView`) stay plain `TimelineView`s: the popover is a separate window that does not inherit the main window's `hfMotionPaused`, and they render only while it is open.
