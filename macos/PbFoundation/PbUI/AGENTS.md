# PbUI

Root AGENTS.md applies (`../../AGENTS.md`).

Shared components and style tokens used by more than one feature. A component that only one feature
package needs belongs in that feature's own `Component/` folder, not here.

- Swift 6 language mode (tools 6.2 default).
- The Phase 0 Monitor redesign (docs/design/monitor-redesign/SPEC.md) restyled this package's
  tokens and components; the redesign supersedes the old byte-identical relocation rule. From here
  on, a visual change here is a deliberate design change made through the SPEC's tokens — every
  colour comes from `Palette`, every font size from `PbTextStyle`, and shared component dimensions
  from `PbRadius`/`PbRadius.Metrics` — never a stray literal.
- Every component and preview-worthy type gets a `#Preview` in `#if DEBUG`, in light and dark
  (plus any state the component treats specially, such as Reduce Motion). Where a MonitorCore type
  (`TaskInfo`, `ParallelGroup`, `TaskNode`, …) has no public initialiser, build the preview through
  its own public API (e.g. `TaskInfo(_:JSONValue)`, `Lineage.sections(_:)`) rather than reaching for
  an internal one. Preview data is explicitly dummy: never invent production counts or values the
  events do not carry.
- `withPresentationContext()` is installed by the main-window and Settings navigation views, once
  for each view's feature subtree; the menu-bar view installs none. Never install it inside a
  component or a feature screen.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), mirroring the source
  paths. They characterize retained behaviour (`Format`, `MarkdownText`'s parser, `EnforcementText`,
  `StatusColor`/`BackendStyle`) and test new presentation logic directly: the status → badge/icon
  mapping and its complete accessibility strings, exact palette values and their ≥ 4.5:1 contrast on
  the surfaces the design names, and the motion override's true/false/nil resolution
  (`PbMotion.reduceMotion`). Render-level fixtures (`DesignFoundationRenderingTests`) are
  deterministic under Reduce Motion, write no files in an ordinary test run, and only produce PNGs
  when their own opt-in output variable names a staging directory.
- Presentation motion is overridable only through the presentation-only `pbReduceMotionOverride`
  environment value (nil follows the system). No VM publishes it, nothing persists it, and it is
  never a user setting.
