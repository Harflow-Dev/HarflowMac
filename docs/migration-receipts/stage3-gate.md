# Stage 3 gate

Stage 3 workflow acceptance is in progress. This receipt records the verified
checkpoints toward the full gate.

## Window-test follow-up

The focused three-suite run on `392bc880` recovered the New Task dark 1000×620
owned-window capture and passed all 22 picker definitions. The earlier
intermittent screenshot failure and picker abort remain in the historical
[Stage 2 receipt](stage2-gate.md). This checkpoint establishes passing results
for both suites on unchanged source.

The toolbar failure reproduced on pane close and Escape. A temporary diagnostic
confirmed two native focus candidates per affected button. The guarded selector
declined to choose an ambiguous target, and the window fallback cleared the
accessibility focus label. The diagnostic source was restored.

The chip Buttons now use standard macOS focus policy. Their style, accessibility
bindings, guarded target selection and fallback are preserved. With Keyboard
Navigation enabled, the guarded suite verified unique chip targets, exact
native key-loop reachability, and native focus return after close and Escape.
The first candidate run reached the chips in reverse from More actions and
passed the return assertions. The owner accepted reachability in either native
direction. The resulting full toolbar suite passed all 15 definitions with
no skips on UID 503. The owner deferred Keyboard Navigation off verification.
The focused chip's ring remains an item for the Stage 3 owner visual check.

Astra and Opus approved the plan in round 3 and the integrated diff in the
first code round. Evidence and adjudication are under `.claude-work/mac/stage3/`.

## Workflow run header and summary pane

Design approval is pinned to HarflowDesign
`70d94ef16173b7f48bc72d4930949f3df0b0b7cd`, in
`v2/docs/decisions/run-top-bar.md` and `v2/docs/decisions/parallel-run-pane.md`.
The existing run header shows its started time and repository without a More
actions menu. The running row still derives elapsed time from its observed start.
The header line was exercised in the guarded workflow run fixture. Elapsed time
in the app sidebar remains part of the full-shell visual check.

The regular run summary now has the shared Show/Hide right pane control in
Graph with no selected node and in Parallel. It retains Original request,
Goal, Plan and Technical plan. A hidden pane is removed from the split and
accessibility tree. The same run keeps its choice across Graph and Parallel.
Selecting another run resets the choice. Selected nodes and recovery retain
their presentations. An admitted caller approval panel or active goal draft
opens and keeps the pane reachable. Both layouts restore the saved user width.
At 660 points of detail width, Parallel retains the 288-point inspector beside
at least 360 points of activity. Graph keeps its 400-point canvas reserve.

The guarded final candidate `c918e0b1cb94…` passed all 38 discovered definitions
across the exact AppKit visibility suite, original approval and sidebar suite,
direct run layout and main-shell viewport. There were zero issues or skips.
The existing toolbar and recovery suites separately passed with the same
production behavior. Twelve exact owned-window captures cover Graph and
Parallel, light and dark, and expanded, hidden and reopened states at
1000×620 fixture content size. The ordinary sidebar suite kept its existing
backend. The new visibility suite alone uses the isolated AppKit test host. The runner
self-test passed all 613 definitions with process access.
Evidence is under `.claude-work/mac/stage3/run-pane-7/`.

Astra and Opus approved the plan and code by round 3. Keyboard traversal
of the new control, full-shell header fit and populated Parallel lanes at
normal size remain Stage 3 acceptance items. Spoken VoiceOver remains deferred
to M12. The final MainWindow gate and Harflow Check build are pending.

## Workflow steering public adapter

MonitorCore now reads workflow steering status and bounded history and
submits steering requests through the public `harflow-ctl --monitor`
operations. Requests use private file input and exact root and episode
bindings. HfRepository owns the attempt lease and can distinguish a confirmed
pre-admission refusal from an indeterminate result. An indeterminate result
keeps dependent sends fenced. A later exact history match establishes
admission only. Resume and Dismiss remain subject to engine-reported
eligibility.

The slice is pinned to the selected Python producer `v0.0.14` at
`a891388b1259add2ec8432d7d0fc5ca38163c27d` for the audited refusal proof.
Astra and Opus approved the plan in round 3 and the integrated candidate in
code round 2. The final MonitorCore check passed 31 definitions in seven
suites. The HfRepository check passed 17 definitions.
Both scoped checks used fixture data via the guarded runner and shared build
lane. No live engine was invoked. Native steering presentation and keyboard
checks follow in the UI slice.
