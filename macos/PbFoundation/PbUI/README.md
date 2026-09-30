# PbUI

Shared visual components, style tokens, and the `ViewEvent` presentation modifier. Moved out of the
app target's `Style.swift`/`InspectorView.swift`/`SidebarView.swift` as Phase 2 ("package skeleton")
of `.claude/plans/2026-09-25-monitor-architecture-plan-settled.md` (item D) — every string, size,
font and colour is byte-identical to what shipped before the move.

## What's here

- **Style tokens & components** (`Style.swift`, `Palette.swift`): the `Color(hex:)` palette, the
  type scale (`PbTextStyle`), radii (`PbRadius`), `FreedomBadge`, `StatusPill`, `Chip`,
  `SectionLabel`, `MarkdownText` (with its limited block parser), `Banner`, `Format`,
  `StatusColor`, `BackendStyle`, `AccessLabel`.
- **Backend and status components**: `BackendDot`, `BackendLabel`, `BackendDotStack`, `StatusIcon`,
  `ActivityCard`, `TaskRow`/`TaskRowModel`, `GroupRow`.
- **`EnforcementText`** — moved from `InspectorView.swift:~160-186`: plain sentences for
  `enforcement` claims that are explicitly `true`, plus the Parallel view's cross-task intersection.
- **`GroupRow`** — moved from `SidebarView.swift:~145`: it took only a plain `ParallelGroup` value
  and never read `AppModel`, so it qualified for this layer as-is (the plan's own qualifying rule).
- **`withPresentationContext()`** (`Modifier/ViewPresentationContextModifier.swift`) — renders a
  `ViewEvent.alert` as a native SwiftUI `.alert` and `.dialog` as a `.confirmationDialog`, buttons'
  roles (destructive/cancel) preserved. **Not applied to any scene yet** — Phase 4/5 replaces the
  app's four existing `confirmationDialog`s with `ViewModel.publishAlert`/`publishDialog` and applies
  this once per scene (Settings included).

## Build & test

```bash
cd macos/PbFoundation/PbUI
swift build
swift test
```

## Dependencies

Local: `PbUtilities`, `PbCommon`, `MonitorCore` (by path — `TaskInfo`, `TaskStatus`, `ParallelGroup`,
`JSONValue`). No remote dependencies of its own.
