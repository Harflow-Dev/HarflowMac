# Stage 3 gate

Stage 3 workflow acceptance is in progress. This receipt currently records the
window-test work carried forward from Stage 2.

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
