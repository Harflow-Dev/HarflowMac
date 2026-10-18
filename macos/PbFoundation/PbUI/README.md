# PbUI

Shared visual components, style tokens, and the `ViewEvent` presentation modifier. Originally moved
out of the app target as Phase 2 ("package skeleton") of the Monitor architecture plan; the Phase 0
Monitor redesign (docs/design/monitor-redesign/SPEC.md) then restyled its tokens and components to
the approved design — colours now come from the SPEC §3 palette, font sizes from `PbTextStyle`, and
shared component dimensions from `PbRadius`/`PbRadius.Metrics`.

## What's here

- **Style tokens** (`Style/Palette.swift`, `Style/Style.swift`, `Style/PbMotion.swift`): the
  appearance-aware `Color(hex:)` palette (`Palette`, with an exhaustive `Palette.all`), the type
  scale (`PbTextStyle`), radii and shared component metrics (`PbRadius`, `PbRadius.Metrics`),
  `FreedomBadge`, `StatusPill` (a live-clock owner over `StatusBadge`), `Chip`, `SectionLabel`,
  `MarkdownText` (with its limited block parser), `Banner`, `Format`, `StatusColor`, `BackendStyle`,
  `AccessLabel`, and the presentation-motion helper (`PbMotion`) with its presentation-only
  `pbReduceMotionOverride` environment value.
- **Backend and status components**: `BackendDot`, `BackendLabel`, `BackendDotStack`, `StatusIcon`,
  `RunningSpinner`, `StatusBadge` (the one shared status capsule), `ActivityCard` (padded) plus
  `GroupedActivityCard`/`ActivityCardRow`/`ActivityCardDivider`/`ActivityDiffBody`/`ActivityDiffLine`
  (unpadded grouped-card and edge-to-edge diff primitives), `GroupedForm`/`GroupedFormRow`/
  `GroupedFormDivider`, `CompactStepper` (native minus/value/plus buttons with caller-owned bounds),
  `GroupedFormPopup` (native menu with caller-owned selection), `SlidingSegmentedControl`,
  `TaskRow`/`TaskRowModel`, `GroupRow`.
- **Buttons**: `MonitorButtonStyle` (primary/tinted/destructive, plus the opt-in SDK-glass kind for
  chrome) and `QuietButtonStyle` (the neutral toolbar/content button; a destructive Quiet button is
  the tinted danger capsule). Glass is opt-in — content is never glass.
- **`EnforcementText`** — plain sentences for `enforcement` claims that are explicitly `true`, plus
  the Parallel view's cross-task intersection.
- **`GroupRow`** — the sidebar's parallel-group row, plain `ParallelGroup` value only.
- **`withPresentationContext()`** (`Modifier/ViewPresentationContextModifier.swift`) — renders a
  `ViewEvent.alert` as a native SwiftUI `.alert` and `.dialog` as a `.confirmationDialog`, buttons'
  roles (destructive/cancel) preserved. The main-window and Settings navigation views each install
  one presentation context for their own feature subtree; the menu-bar view installs none.

## Build & test

```bash
cd macos/PbFoundation/PbUI
swift build
swift test
```

Ordinary tests render fixtures offscreen and write no files. The foundation render fixture writes
PNGs only when `PB_DESIGN_FOUNDATION_OUTPUT` names a staging directory inside the system temporary
directory (used by the local design-reference capture workflow).

## Dependencies

Local: `PbUtilities`, `PbCommon`, `MonitorCore` (by path — `TaskInfo`, `TaskStatus`, `ParallelGroup`,
`JSONValue`). No remote dependencies of its own.
