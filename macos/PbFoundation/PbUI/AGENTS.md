# PbUI

Root AGENTS.md applies (`../../AGENTS.md`).

Shared components and style tokens used by more than one feature. A component that only one feature
package needs belongs in that feature's own `Component/` folder, not here.

- Swift 6 language mode (tools 6.2 default).
- Keep every moved component byte-identical in strings/sizes/fonts/colours — this package's job in
  Phase 2 was relocation, not redesign. A visual change here is a Phase 4/5 decision, not this one.
- Every component and preview-worthy type gets a `#Preview` in `#if DEBUG`. Where a MonitorCore type
  (`TaskInfo`, `ParallelGroup`, `TaskNode`, …) has no public initialiser, build the preview through
  its own public API (e.g. `TaskInfo(_:JSONValue)`, `Lineage.sections(_:)`) rather than reaching for
  an internal one.
- `withPresentationContext()` is applied once per scene, by the app shell (Phase 5) — never inside a
  component or a feature screen.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`); they characterize
  existing behaviour (`Format`, `MarkdownText`'s parser, `EnforcementText`, `StatusColor`/
  `BackendStyle`) rather than testing new logic.
