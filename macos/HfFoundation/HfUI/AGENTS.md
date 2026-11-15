# HfUI

Root AGENTS.md applies (`../../AGENTS.md`).

Shared components and style tokens used by more than one feature. A component that only one feature
package needs belongs in that feature's own `Component/` folder, not here.

- Swift 6 language mode (tools 6.2 default).
- Visual changes use the shared design tokens: every
  colour comes from `Palette`, every font size from `HfTextStyle`, and shared component dimensions
  from `HfRadius`/`HfRadius.Metrics` — never a stray literal.
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
  (`HfMotion.reduceMotion`). Render-level fixtures (`DesignFoundationRenderingTests`) are
  deterministic under Reduce Motion, write no files in an ordinary test run, and only produce PNGs
  when their own opt-in output variable names a staging directory.
- Presentation motion is overridable only through the presentation-only `hfReduceMotionOverride`
  environment value (nil follows the system). No VM publishes it, nothing persists it, and it is
  never a user setting.
- `StatusIcon` draws the approved task status glyphs (HarflowDesign `fe6428c`): plain, no disc, `StatusIcon.glyph(for:kind:)`,
  `tint(for:kind:)` and `accessibilityLabel(for:kind:)` are the tested tables, and `symbolName(for:)` is derived from the task
  glyph. SF Symbols draw check, x and filled stop; `StatusGlyphShape` (workflow, parallel, hand) transcribes the design's SVG
  paths and `StatusGlyphView` strokes them (icon 14/16 of the frame, stroke 1.8/24, round caps and joins, foreground style).
  `StatusIcon.Kind` (`task`, `workflowRun`, `parallelGroup`) selects the workflow and parallel glyphs; `TaskRowModel.kind`
  carries it. `GroupRow` shows the parallel glyph while several members run (accent) and once every member has finished
  (`doneGreen`, whatever the outcomes, labelled "Parallel group, done"); a single running member shows the running spinner,
  and a finished group of one keeps its backend dots; no group row has a trailing spinner. Icon labels follow the design's
  `aria-label`s ("Needs you", "Parallel group, running", "Done" for a workflow run) while badges keep their words
  ("Needs attention"); that difference is accepted. `StatusBadgePresentation.Indicator.glyph` and `StatusIndicatorView` draw the
  hand outside `StatusIcon`. Out-of-set states (pending, paused, unknown) keep their circles and triangle.
