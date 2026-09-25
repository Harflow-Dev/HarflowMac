# PbTerminal

Root AGENTS.md applies (`../../AGENTS.md`). Read this module's `README.md` before editing.

- **The only module allowed to import SwiftTerm**, with `@preconcurrency import SwiftTerm`. Nothing
  above this package (a feature, the app shell) may import it directly — go through
  `TerminalSession`/`TerminalHost`/`TerminalSessionRegistry` instead.
- **Swift 5 language mode** (`swiftLanguageModes: [.v5]`), same reason as `MonitorCore` (decision 2):
  the SwiftTerm delegate hops kept from today's code (`MainActor.assumeIsolated` around a nonisolated
  `LocalProcessTerminalViewDelegate` callback) do not compile under Swift 6's strict concurrency
  checking. Moving this package to Swift 6 is separate work, not part of this refactor.
- `TerminalSessionRegistry` and `TakeoverService` are `@MainActor` — an explicit exception to the
  repository layer's `nonisolated`/`Sendable` rule (decision 12), because both own `NSView`-backed
  `TerminalSession`s. Their `@GlobalEntry` defaults (`NullTerminalSessionRegistry`,
  `NullTakeoverService`) are deliberately **not** `@MainActor`: each protocol requirement is
  witnessed as `nonisolated` on an otherwise-plain type, so the default never calls a `@MainActor`
  initializer before any module has registered a real value (the root AGENTS.md's rule 6). This is
  the "nonisolated dummy" option, not "register a lazily created instance" — a lazy instance would
  still need a `@MainActor` hop to construct on first access, which is exactly what the rule forbids.
- Depends on `PbRepository`, `MonitorCore`, `PbUtilities`, and (remote) SwiftTerm 1.20.0, Mockable
  0.6.2, SwiftEnvironment 4.1.8, pinned exactly. Does **not** depend on `PbCommon` or `PbUI` — nothing
  here imports either, and Core-layer packages must not depend on Foundation/UI-layer ones (the root
  AGENTS.md's package graph). Where a UI-layer helper was needed (`Format.repo` for an interactive
  session's title), it is `PbRepository.RepoPathFormat`, made `public` in this phase rather than
  duplicated a third time — see that file's header comment and the Phase 3B report.
- The SwiftUI view rendering a session's status line and close/end buttons
  (`TerminalPaneView`, folded into `MainWindowFeature/TaskDetail/Component/` in Phase 4d) is not
  here: it needs `MainWindowCoordinator`'s navigation seam to remove a session, and this package is a
  Core-layer package that must not depend on a Feature one. See the Phase 3B report for why it was
  never moved here in the first place.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `PbTestUtilities` — never a fixed `sleep`. Process-spawning
  tests (a real `/bin/sh` child, `TerminalSession.start()`) are `.serialized` and kill their spawned
  pids in `deinit`/`defer`, per the root instructions. A test that would need a live window server to
  construct a `LocalProcessTerminalView` is not written; the pure pieces (`WaitStatus` decoding,
  `terminate()`'s join/outcome-mapping logic) are tested behind the seams that do not need one, and
  first-responder reparenting is left for the manual C5 checklist — see the Phase 3B report for
  exactly which tests fall on which side of that line.
