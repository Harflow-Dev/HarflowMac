# PbRepository

Root AGENTS.md applies (`../../AGENTS.md`). Read this module's `README.md` before editing.

- Repositories expose business-level contracts over `MonitorCore` and delegate process/file I/O to
  it. Repository protocols are `@Mockable` and `Sendable`.
- Repositories are `nonisolated` classes/structs, never `@MainActor`. Asynchronous mutable state is
  protected with a lock or a private actor; synchronous snapshots are published with `@Subjected`
  (`PbUtilities`).
- Dependencies between repositories are constructor-injected concrete instances, wired once in
  `Module.initializeModule()` — not `@GlobalEnvironment` property-wrapper lookups inside each impl.
  This is deliberately simpler than per-property `@GlobalEnvironment` lookups: `Module` owns the whole
  vertical construction in one place, so passing the already-built earlier instance directly is
  simpler and equally satisfies "an initializer only resolves values registered earlier" (there is
  no property to resolve lazily — the earlier instance is just a parameter).
- `@GlobalEntry` defaults are hand-written trivial "Null*" structs, not the `@Dummyable` macro:
  several MonitorCore value types the protocols return (`TaskInfo`, `ToolError`, `CtlClient`,
  `TakeoverGrant`, `GitChanges`, …) have no zero-argument initializer and are not themselves
  `@Dummyable`, so macro-synthesized dummies were not a safe bet for every protocol here. A
  hand-written default that returns empty collections / `.notFound` failures / `Empty` publishers is
  simpler to reason about and does not depend on Dummyable's type coverage. `Dummyable` is therefore
  **not** a dependency of this package.
- `PbRepository` depends only on `MonitorCore` and `PbUtilities` — never `PbCommon`/`PbUI` (Core
  never depends on Features/UI; see the root AGENTS.md's package graph). `Format.repo` is
  duplicated locally (`Support/RepoPathFormat.swift`) for this reason — see that file's header
  comment and the Phase 3 implementation report for why it could not be shared instead.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `PbTestUtilities` — never a fixed `sleep`. Timing-dependent
  behaviour (the 1 s throttle, the 10 s poll, the 60 s reconcile) is driven through the injected
  `Scheduling` seam by capturing and manually invoking the scheduled closure, never by waiting on a
  real timer.
