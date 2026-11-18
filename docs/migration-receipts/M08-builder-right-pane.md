# M08 builder right-side activity pane

## Source scope

The workflow builder uses the approved canvas-left/activity-right arrangement instead of the
previous vertical split. The standalone node row spans the workspace above the split. Widths
come from the actual detail viewport after the navigation sidebar: one bounded divider,
activity up to460 points with priority, and the remaining canvas. Canvas nodes retain their
existing dimensions and scrolling. No stacked narrow-window fallback is introduced, and a
selected node does not add another inspector while the builder pane is present.

`TaskDetailChrome.builder` mounts the existing builder VM with transcript metrics, composer,
approval controls and Always allow behavior. It replaces the old280-point Events side pane and
its reveal controls with a compact heading and inline notices, continuity, outcomes and task
facts/result/event disclosures. The existing running-continuity guard remains authoritative.
Group, embedded and standalone mounts retain their behavior. Runtime/session/attempt ownership,
proposal application and Return to canvas eligibility remain unchanged.

Design: `34c3b0576e221d17b1096136db6c5d0fbb4c5000`,
`v2/scripts/screens-workflow-editor.js`, `workflow-editor/edit-with-agent`; subsequent
agent/generate states at `b710856a31702e46e3b8f3a54be19f3cb7c422dc`,
`v2/scripts/states-workflow-gaps.js`. No separate minimum builder design is claimed.

## Observed verification

The final guarded run passed402 discovered definitions across8 pure model suites, with zero
failures and `host_setup={}`. Coverage includes width bounds, invalid/narrow viewports, builder
mount policy, existing task model behavior, transcript metrics, runtime/session ownership,
proposal/candidate handling, draft and polling regressions.

Release app build, bundle checks and ad-hoc signature verification passed without launch, using
two build jobs. Executable SHA-256:
`d201631e7626c8595321bc7eacf1d4e9e60bbeebaf8eb2f491a3173ffbf66c13`.
Formatting, strict lint with zero violations, legacy/private guards and whitespace checks passed.
Independent review closed at round2. Production and hosted fixtures were aligned to transcript
metrics; oversized hosted coverage was extracted into an extension of the same registered suite.

Hosted tests for normal/minimum size in both appearances are prepared but **not executed**.
Actual pane/composer geometry, expanded facts reachability, keyboard/focus and accessibility
acceptance remain deferred until the owner grants a desktop-test cue. No app installation,
real user-state launch, provider execution or full M08/M12 acceptance follows from this receipt.

Generated build output is disposable and was scheduled for owner-requested account-switch
cleanup after verification. Historical hashes do not imply that an executable remains present;
rebuild the isolated controlled host with reconciled exact source guards before desktop testing.

## Hosted failure repair (2026-11-18)

The first guarded hosted run of the builder suites (MainWindowFeature at d4a7245, 400 of 403 suites
passing) failed WorkflowScreenLayoutTests and WindowedWorkflowLayoutTests. Diagnosis used temporary
probe tests through the guarded runner and two independent reviews; the probes were removed.

- **Identifier override.** The canvas and activity identifiers were set on views that were not
  accessibility containers, so SwiftUI applied them to every descendant and replaced the
  descendants' own identifiers. Both regions are now containers with their own labels.
- **Safe-area leak.** Without the local hosting boundary that d4a7245 removed, the floating
  sidebar's leading safe area reached the canvas's AppKit scroll view a second time (canvas
  observed at x=496 and 43 points wide in a 291 point budget). The whole workspace is wrapped in
  `WorkflowPaneViewport` again; the canvas then spans the budget from the sidebar edge.
- **Builder skeleton width.** The builder loading placeholder used fixed widths wider than the
  460 point column and overflowed it during the loading handoff; its blocks now keep their design
  widths only while they fit.
- **Test measurement.** The layout test settled on the composer, which exists before the loading
  handoff reveals the content, and measured the activity column from an accessibility container
  frame, which is not a layout measure. It now settles with the reduce-motion override and measures
  the column with a test-side view probe. The windowed fixture now qualifies its builder runtime
  (the guard from de9fb1ab otherwise clears the run) and mounts production builder chrome; its
  heading landmark replaces the task title the builder chrome does not draw. The builder layout
  tests now start from the preview workflow graph.
- **Regression guard.** WorkflowPaneViewportTests uses production window chrome; with the
  hosting boundary removed it fails ("Builder canvas must start at the sidebar edge"), and the new
  builder skeleton test fails with the fixed widths restored.

Observed after the repair, through the guarded runner: WorkflowScreenLayoutTests (9 tests),
WindowedWorkflowLayoutTests and WorkflowPaneViewportTests passed. The overflow check covers
AppKit-backed views only; the skeleton overlay path is covered by the standalone skeleton test.

**Open for M08 acceptance:** at a 1000x620 window the builder activity column leaves the feed
viewport 0 points tall (header, request and captured-activity lines and the composer fill the
column), while the approved design shows a scrollable conversation. Under this layout the windowed
test's activity predicate proves only that the feed table exists, not that it is visible. No M08
or M12 acceptance follows from this repair.
