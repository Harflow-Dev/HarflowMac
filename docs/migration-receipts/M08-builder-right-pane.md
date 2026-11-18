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
