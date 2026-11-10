# HfRepository

Root AGENTS.md applies (`../../AGENTS.md`). Read this module's `README.md` before editing.

- Repositories expose business-level contracts over `MonitorCore` and delegate process/file I/O to
  it. Repository protocols are `@Mockable` and `Sendable`.
- Repositories are `nonisolated` classes/structs, never `@MainActor`. Asynchronous mutable state is
  protected with a lock or a private actor; synchronous snapshots are published with `@Subjected`
  (`HfUtilities`).
- Dependencies between repositories are constructor-injected concrete instances, wired once in
  `Module.initializeModule()` — not `@GlobalEnvironment` property-wrapper lookups inside each impl.
  This is deliberately simpler than per-property `@GlobalEnvironment` lookups: `Module` owns the whole
  vertical construction in one place, so passing the already-built earlier instance directly is
  simpler and equally satisfies "an initializer only resolves values registered earlier" (there is
  no property to resolve lazily — the earlier instance is just a parameter).
- `@GlobalEntry` defaults are hand-written trivial "Null*" structs, not the `@Dummyable` macro:
  several MonitorCore value types the protocols return (`TaskInfo`, `ToolError`, `CtlClient`,
  `TakeoverGrant`, …) have no zero-argument initializer and are not themselves
  `@Dummyable`, so macro-synthesized dummies were not a safe bet for every protocol here. A
  hand-written default that returns empty collections / `.notFound` failures / `Empty` publishers is
  simpler to reason about and does not depend on Dummyable's type coverage. `Dummyable` is therefore
  **not** a dependency of this package.
- `HfRepository` depends only on `MonitorCore` and `HfUtilities` — never `HfCommon`/`HfUI` (Core
  never depends on Features/UI; see the root AGENTS.md's package graph). `Format.repo` is
  duplicated locally (`Support/RepoPathFormat.swift`) to preserve this dependency boundary.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `HfTestUtilities` — never a fixed `sleep`. Timing-dependent
  behaviour (the 1 s/30 s public observation cadence and readiness/preparation retries) is driven through the injected
  `Scheduling` seam by capturing and manually invoking the scheduled closure, never by waiting on a
  real timer.

- Stop acknowledgement state belongs to `TaskActionRepository` for the app session, not to a
  task VM or disk. `TaskSnapshotRepository.readRevision` uses an independent clock: its getter
  must not acquire the snapshot-state lock or invoke callbacks, because acknowledgement samples
  it while holding the action-state lock. New read/eviction and stopping invalidations publish
  after their state locks release; raw snapshot/list getters stay outside the action lock.
  Preserve per-attempt freshness, authoritative revisioned eviction and qualified-set dedup.
  Do not infer acknowledgement from durable outcome text or signal/settlement from Stop requested.

- Continue attempts belong to the shared `TaskContinuationRepository`, scoped by captured runtime,
  conversation and full source ID, with source-alias deduplication. Preserve invocation outcome
  independently of recorded-successor evidence. Empty/failed/incomplete reads never clear unknown;
  acknowledged is not completed. Keep unsafe records across navigation/runtime changes, no automatic
  launch retry, no engine-private fallback, no lock held across dependency calls/await/publication.
  Busy is shared only during invocation; future UI must consume the separate owner state. Bounds
  refuse admission rather than forgetting unsafe evidence. The standalone task caller must combine owner state with fresh current-target status authority.
