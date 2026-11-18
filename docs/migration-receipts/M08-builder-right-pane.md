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

### Verification status at cb36456e

- The three originally failing suites pass through the guarded runner at `cb36456e` on a clean
  tree: WorkflowScreenLayoutTests (9 tests), WindowedWorkflowLayoutTests and
  WorkflowDeleteHostedTests. WorkflowDiscardHostedTests, the new PresentationEscapeHostedTests
  (7 tests), eleven neighbouring builder, canvas, composer, transcript and stop-confirmation
  suites, the HfUI package (270 tests) and the runner's own tests (759) also passed.
- Independent review (Opus and Astra) closed at round 3 with no open findings.
- **Full MainWindowFeature suites gate: PENDING, postponed by the owner, not failed.** The first
  attempt stopped before any suite ran because the AppKit test host could not become active while
  the Mac was in use. The second attempt was stopped on request after 22 suites, all passing, so
  the Mac could be used; no test host was left running. Run it when the Mac is free.

## Selected-node activity surface (2026-11-18)

The Graph selected-node activity pane drew a 3 point status-coloured strip across its top on a
card-fill surface, a leftover of the pre-v2 inspector. The approved pane (HarflowDesign
`7de89a47137c261e5a1baaf4ef6504eb9e67a267`, `.hd-pane` in `v2/styles/bundle.css`; states
`workflow-run/graph-needs-you` and `workflow-run/on-demand` in `v2/scripts/screens-workflow-run.js`)
uses the page background and shows status only as a badge. The strip and its tint mapping are
removed, and the whole selected-node pane, including the native activity view that shares it, now
draws the page background. The status badge remains beside the node's title in the activity column's
header. The default run sidebar, the run inspector loading skeleton and the editor inspector still
use the card fill and are left for a consistency follow-up.

Observed: the package and its tests compile through the guarded runner. The rewritten rendering
tests have not run yet (see the pending hosted batch below).

## Builder feed height at the minimum window (2026-11-18)

Closes in code the acceptance blocker recorded above; the hosted proof is pending.

At a 1000x620 window the builder's activity feed viewport was 0 points tall. The header's feedback
area had a flexible frame (height cap only), so the column's stack gave the header half of the 433
point column and the column's fixed parts used the rest. The approved design
(`34c3b0576e221d17b1096136db6c5d0fbb4c5000`, `v2/scripts/screens-workflow-editor.js`,
`workflow-editor/edit-with-agent`) shows a fixed pane head over a scrolling conversation.

- The builder's title and backend rows stay pinned. The approval banner, the header feedback
  (outcome, banners, notices, continuity, the facts disclosure) and the resource card form one
  region that scrolls with a 48 point floor when it does not fit. The approval banner now sits below
  the pinned rows instead of above them.
- A builder-only layout gives the column at least its minimum, places it directly under the top
  region's actual height, and caps the top region at half of the column, so tall windows keep most
  of the space for the conversation. Its sizing is a pure function covered by
  `TaskBuilderColumnSizingTests`.
- The builder feed keeps a minimum of 80 points; other mounts are unchanged.

Observed: `TaskBuilderColumnSizingTests` (9 tests) passed through the guarded runner; the package
and its tests compile. Estimated, not observed: at 1000x620 the feed is about 113 points with the
facts collapsed and at its 80 point floor with the facts expanded, three long notices, or the
approval banner and resource card, with about 21 points of margin. Two or more history rows or a
copy-feedback line could exceed it; the hosted run settles this. Acceptance of the minimum-window
builder still depends on that run.

## Pending hosted batch

Not run while the owner uses the Mac; to run in one batch through the guarded runner when it is
free. Suites that open on-screen windows:

- MainWindowFeature full `--mode suites` gate (postponed, see "Verification status at cb36456e").
- `ParallelColumnsRenderingTests`: `givenAnInspectorColumn_whenRendered_thenItHasThePageBackgroundAndNoStatusStrip`
  (light and dark) and the corner check of `givenAParallelLane_whenRenderedAtItsActualBoundary_thenItsBottomCornersAreTheChromeSurface`.
- HfUI package aggregate (several of its suites order windows front).
- Workflow selected-activity hosted coverage that mounts `WorkflowSelectedSidebar`.
- `WorkflowScreenLayoutTests` builder feed cases:
  `givenBuilderColumnScenario_whenHosted_thenFeedKeepsAScrollableHeightAndEverythingIsInsideTheColumn`
  (16 cases; its banner-and-card containment does not prove the card is visible),
  `givenFactsExpandedWithBannerAndCard_whenHosted_thenTopRegionScrollsAndItsLastControlWorks`,
  `givenFactsCollapsed_whenHosted_thenColumnStartsRightBelowTheNaturalTopRegion` (leaf frame gap;
  only its gap check is evidence) and `givenNonBuilderMount_whenHosted_thenFeedAndComposerKeepTheirColumn`
  (a smoke check only, not proof of unchanged geometry).
- `WindowedWorkflowLayoutTests`: the builder feed viewport height assertion.
