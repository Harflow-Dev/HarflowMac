# Stage 2 gate

The focused Needs you retry closed the missing Stage 2 capture on the tested commit.
Owner visual and spoken VoiceOver checks and sign-off remain pending. Three Stage 1
fixture failures remain recorded from the full MainWindow run.

## Scope

- M06 queued follow-ups, cancellation, Send now and explicit continuation. M07 exact-action inline approvals,
  Needs you and supported workflow question/checkpoint handling. Design references are HarflowDesign
  `30b7e9d`, G-QUEUE and G-APPROVAL-STATES in the v2 migration coverage ledger, and the approved
  Needs you workflow question-card states in HarflowDesign `ee51b74`.
- Use the guarded runner, with separate owner grants for MainWindowFeature and MenuBarFeature on UID 503.
  Record owned-window pixels and the fixture's keyboard and accessibility checks.
- Build a fresh Harflow Check from the tested commit. Use `dev.harflow.mac.check` before build, omit URL
  types, verify the ad-hoc signature and leave the app unlaunched.
- Evidence outside the repository under `.claude-work/mac/stage2/`.

## Candidate

`a0c5b759fe796c06556946fea1a35ef07e915b4e`, local `main`. Send now requires current
`messaging.v1` support and a running Task Detail target. A fresh task read validates Now
admission at click time. Queued Send, explicit continuation and accepted approval reachability
retain their prior behavior.

Both Astra and Opus approved the plan and source in two rounds. The revisions preserved the
approved settled hint, added current-source admission for non-standalone mounts and covered
running and settled tasks across four mounts, stale capability and stale takeover cases. The additional
identity guard is confined to Now. The Opus API route reported insufficient credit and Claude
Code Opus performed the independent reviews. Full adjudication is in the stage 2 workspace status.

## MainWindow run 1

2026-11-20, 18:24:10–19:03:24 WIB, UID 503. The selected Xcode Swift toolchain ran
the full guarded MainWindowFeature suite with exact suite isolation on the shared lane.
The test host used a scratch home and the desktop remained available through completion.
The keyboard navigation setting was already enabled. The runner validated the fixtures'
event streams and produced a manifest.

| Check | Result |
| --- | --- |
| MainWindowFeature | 414 of 418 suites passed. Passing suites account for 4,022 of 4,068 test definitions. No explicit skips. |
| Ordinary TaskDetailVMTests on the reviewed diff | 260 of 260 definitions passed, including the Send now corrections. The full gate also passed this suite. |
| Stage 2 product coverage | Hosted message bubbles, composer and explicit continuation passed. Transcript approval, pinned bars and the 21-test workflow sidebar suite passed. Ordinary Needs you suites and the five interactive question definitions passed. The separate question matrix capture is detailed below. |
| Static checks | Full SwiftFormat and strict uncached SwiftLint passed. Legacy-name, private-reference and diff checks passed. |
| Runner and CI tooling | 759 tests and 30 subtests passed. |

### Suite failures

| Suite | Actual result and classification |
| --- | --- |
| `M04StateMatrixHostedTests` | The optional New Task composer-ready capture at 1000×620 in dark mode failed. The active/visible guard passed, but `screencapture` could not create the window image. Stage 1 surface. |
| `ModelPickerStatesHostedTests` | AppKit aborted in the first Recent-chip test while forming a weak reference to `NSKVONotifying__NSPopoverWindow`. The picker handoff records the same crash signature in an earlier attempt. Stage 1 surface. |
| `NeedsYouQuestionCardHostedTests` | One of 16 layout/appearance cases failed capture because the 1280×800 unavailable-question fixture lost AppKit activation after its frame wait. The other 15 cases emitted captures and the other five test definitions passed, including keyboard submission, exact offered answer, same-ID replacement and sibling focus. Stage 2 evidence gap. |
| `TaskTopBarIntegratedHostedTests` | Toolbar chip focus did not return after pane close or Escape. The pane opened and closed and initial group focus passed. The fixture uses a production Task Detail VM with supported running status and tests no sends. Historical gates include the same focus-return assertion failures and later passing runs. Cause in this run is open, including any indirect focus timing from initial composer mounting. Stage 1 surface. |

## MenuBar run

2026-11-20, 19:03:49–19:05:29 WIB, separately approved. The guarded MenuBarFeature
aggregate passed 99 of 99 definitions across 10 suites with no skips at the same commit.

## Captures and keyboard

The actual hosted captures were inspected for queued Send and Cancel in light mode, uncertain
delivery in dark mode, the blocked transcript approval, the single and scrollable labelled
approval bars at 1000×620 in light and dark, and the Needs you text and unavailable question
cards at minimum size. The approval and question suites exercised keyboard and
accessibility behavior. Spoken VoiceOver and the integrated Check walkthrough are owner checks.

## Harflow Check build and runtime evidence

A fresh Release arm64 bundle was built from the tested commit's Git archive. The scratch export
set the check identity before invoking Xcode. Strict deep ad-hoc signature verification passed.
The bundle identifier is `dev.harflow.mac.check` and URL types are absent. Executable SHA-256 is
`f9718900c4461658fda8526f5f56c0007032eca0ae8262d36e075ddf134a0717`.
Bundle and build logs are under `.claude-work/mac/stage2/check-a0c5b759/`. The app was left unlaunched.
The managed-runtime seeding and public reads in [Stage 1](stage1-gate.md) are historical.
This gate's runtime-facing evidence comes from guarded fixtures.

## Targeted rerun

2026-11-20, 20:35:04–20:35:23 WIB, on the same `a0c5b759` commit. The owner explicitly
approved one focused retry on UID 503. The guarded runner passed all six
`NeedsYouQuestionCardHostedTests` definitions with no skips and produced all 16
layout captures. The recovered 1280×800 dark unavailable-question capture was
inspected. It shows the unavailable message, a retained draft, and a disabled
Send answer control. Evidence is under `.claude-work/mac/stage2/run-needs-you-2/`.
The original full-run result and three remaining Stage 1 failures stand.

## Owner check

Use the Check bundle with an isolated generated fixture and verified managed-runtime and
preference isolation, as documented in [development.md](../development.md).
Review the following in light and dark, including the 1000×620 minimum window.

- In Task Detail, inspect supported running Send now, the unsupported composer lock and queued
  Send without Send now on a settled task. Confirm queued Cancel, focus on the resulting
  outcome, delivery/refusal copy and no replay when choosing an eligible explicit Continue.
- In the transcript, Needs you and menu bar, inspect exact-action scope, request labels,
  expiry, answered-elsewhere and stale Refresh. At minimum size, the feed and goal yield
  space to the approval controls. For multiple requests, scroll to each separately labelled
  decision bar.
- In Needs you, inspect question editing, sending, replacement and open-run routing.
  Confirm the menu question Answer action opens the corresponding Needs you destination.
  Check checkpoint refusal and refresh before offering another action.
- Walk the keyboard order and listen to VoiceOver for request targets, decision names,
  draft focus and settlement announcements. Fixture accessibility and key assertions
  supplement the spoken VoiceOver pass.

The public contract identifies the answer channel. More specific answering identity requires
a contract change. Current Mac refusal copy covers the known cases, with additional drawings
still open in the coverage ledger. Direct inline question submission in the menu bar needs
an approved design. The delivered menu question flow uses the existing Needs you routing.
Signing, distribution and broader M07/M12 migration acceptance require their own evidence.
