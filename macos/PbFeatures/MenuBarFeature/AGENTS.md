# MenuBarFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The status-bar item: `MenuBarLabel` (icon + running count, always alive) and the popover content
(`MenuBarView`), both driven by one shared `MenuBarVM` built by `MenuBarCoordinator`.

- Swift 6 language mode (tools 6.2 default).
- Depends on `PbUtilities`, `PbCommon`, `PbUI`, `MonitorCore`, `PbRepository`.
- Running rows tail their task's events via `EventStreamRepository` leases, acquired per row on
  appear and released on disappear (or when the VM itself tears down) — never in `init`.
- Roots come before sub-tasks; at most 3 recent groups and 6 recent roots. Ordering *within* the
  roots/sub-tasks groups is existing, undefined behaviour — do not add a stabilising sort.
- The window opener is captured once, in `MenuBarLabelView.onAppear`, and registered through the
  new `PbCommon.WindowPresenting` seam (see that file's header for why it was added here) rather
  than reaching into the app target directly — features never import the app target.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `PbTestUtilities`.
