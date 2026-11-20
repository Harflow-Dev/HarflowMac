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
