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

## Aggregate gate

The gate ran on `8c595397` with the guarded runner, through the shared build lane, under UID 503 with Keyboard
Navigation on. Evidence is under `.claude-work/mac/stage3/run-stage3-gate-1/`.

- **Passed:** both repository guards, the swiftformat lint, pytest, and the aggregate runs of HfCommon, HfUI,
  HfUtilities, HfRepository, MonitorCore, MenuBarFeature, SettingsFeature and the Harflow shell.
- **Strict lint:** one violation, cyclomatic complexity at `TaskDetailVM+ChangesText.swift:77`, from `afcf9b8e`.
- **MainWindowFeature:** 423 of 430 suites passed. A solo rerun failed the same 7 suites identically.

### Resolution of the seven failures

- **Stale after the running composer (`a78b1c49`):**
  - M05ActionsTopBar, M05Pane and M05Status looked for a "Stop" control and expected "Send" while running.
  - The standalone slot now shows "Stop task", or "Stopping…" while stopping, as HarflowDesign `5539168` (record
    `8312376`) draws for `task/running-composer-empty`/`-draft`.
  - The matrices now find the slot by identifier. The `M05StateTable` entries record a deviation for the states the
    design did not redraw (`running-stop`, `stop-requested`, `owner-lost`, `unverified`, `continue-started`,
    `pane-running-closed`, `stop-dialog*`). Those drawings show the legacy bordered stop control, so the slot there is
    a native generalisation by `a78b1c49`, pending the owner's visual pass.
  - The vacuous `!has("Stop")` checks now also assert the absence of "Stop task", or a positive "Send" slot.
- **Stale after the inline Events usage group (`8839cf74`):** TaskPaneHostedTests' Events document was too short to
  restore its offset. Conversation A now has 40 observation records, and both mounts assert a scroll range of at least
  220 pt.
- **Stale after the message-admission gate (`ecc3e7a8`):** WorkflowActivityComposerHostedTests never subscribed, so
  every send was refused. The test now subscribes, awaits the sidebar, and asserts the admission preconditions.
- **Stale after the inspector document (`ae337f06`):** WorkflowRedesignLayoutTests looked for the removed call-list
  container. It now scopes the call-selector buttons to their shared document scroll view, checks the order and a
  single CALLS heading, and confirms that no scroll view is nested inside that document. The default run sidebar stays
  mounted at opacity 0 underneath, so window-wide geometry is not used.
- **Product regression: WorkflowStandaloneHostedTests.**
  - `ae337f06` routes the orchestrator through a measured layout. Its switch to retained steering replaces the
    `WorkflowSelectedActivityView`. The replaced view's zeroing `onDisappear` (from `054713ab`) could then arrive after
    the new view had measured, emptying the activity column.
  - `ParallelVM` now owns the inspector viewport through claims, using `ParallelViewportClaims`:
    - the newest live view that has measured a width wins;
    - a released view can return only through `onAppear`, with its last geometry, and its later reports are ignored;
    - while live views exist but none has measured, the width is held;
    - suspension and disappearance reset the live claims.
  - The lane path is unchanged.
  - Unit tests failed first against the earlier claim model, then passed.
  - The hosted suite, including a repeated layout-switch test, passed in four consecutive guarded runs.

Strict lint is clean after `reconcileChangesSelection` was split into a behaviour-preserving helper, with per-branch
tests. More → Stop is now covered: a generic `TaskDetailView.toolbarActions` factory, the only construction site in
the view, binds `cancel` to `didTapCancel`. Binding tests cover standalone and group chrome.

Reviews used Opus and Fable; Astra was paused by the owner from 2026-11-22 because of its usage limit. The plans and
the code were reviewed adversarially in two rounds each, and every finding is recorded in `.claude-work/mac/stage3/`
(`gate-red-fixes-plan.md`, `STATUS.md`).

### Closing MainWindowFeature run

On the candidate committed as `efcf95ab`, the full MainWindowFeature `--mode suites` run passed 432 of 432
suites under the lane (`run-gate-red-hosted-4/`). Its fingerprint before and after matched the working tree. The
focused hosted reruns in `run-gate-red-hosted-1` to `-3` resolved the remaining test-only scoping issues along the
way. The other packages' aggregates from the first gate run are unaffected: the fix commit touches only
MainWindowFeature.

### Open items

- **Owner visual pass:**
  - the trailing "Stop task" next to the banner Stop in `owner-lost`/`unverified`;
  - the popover re-anchoring when the repository pill changes width;
  - the focused toolbar chip's ring.
- **Deferred to their own slices:**
  - Events toolbar pointer reveal, focus return and minimal reveal scrolling;
  - Inline Changes: clipboard transfer, multiple open diffs and manual continuation;
  - Statistics: Agent time, Tasks per day, By harness, the Tasks-ranking resume rows, and the additive engine field
    (`spawned_by`/`root_task_id` plus an active-successor flag).
- **Known limitations:**
  - **Coverage gaps:** the composer's Cancel and Escape checks use a shell-equivalent sheet binding, not the full
    `MainWindowNavigationView`. The bordered `task-composer.stop` branch is no longer reachable from a view model.
  - **Events reading position:** a long Result can clamp the Events reading position before its markdown parse lands
    (since `8839cf74`).
  - **Inspector viewport claims:**
    - a leaked live viewport token holds width and leases until suspension;
    - a released token evicted from the 16-entry list could revive through a late report;
    - a teardown width of 0 from an outgoing view briefly drops the column before the next view measures.
  - **Test weaknesses:**
    - `WorkflowActivityMessageTests.swift:114-123` can be refused by admission rather than its disabled reason;
    - the reconcile tests infer cancellation through the patch-generation fence;
    - the group toolbar contrast checks only the dialog title.
- VoiceOver remains deferred to M12.
