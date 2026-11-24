# Stage 4 gate

Stage 4 (M11) covers areas A (engine and runtime states, HarflowDesign `e1c9230`), B (harness settings) and C (menu
bar and notifications), both at HarflowDesign `8ec4d38`. This receipt records the combined hosted batch, how each red
was resolved, and the closing runs. Plans, review ledgers and run output are under `.claude-work/mac/stage4/`.

## Slices

| Area | Commits |
|---|---|
| A | `d184aa89`, `29f164d0`, `bddb33a6`, `3321b17b`, `851b1f27`, `69a8b89b`, `d2ff5ffd`, `705d920d` |
| B | `b5034554`, `0b6672c6`, `9dd67c0e`, `7c129fee` |
| C | `0e7421fd`, `25c61129`, `64aa7c7f`, `731ef383`, `78f1768b`, `476cccdf` |
| Gate fixes (test-only) | `0dd2b3ab`, `0cab4b27`, `46b964c0` |

Sonnet implemented every slice. Fable reviewed each one adversarially, for at most three rounds, and its approvals and
adjudications are in `areaBC-plan.md` and the area A plans. Opus and Astra were paused for this stage. Non-hosted suites
passed for each slice before the batch ran.

## Combined hosted batch

The batch ran once on `476cccdf` (2026-11-24, 12:22–13:09 WIB). It used the guarded runner, one package at a time,
through the shared build lane:

| Package | Mode | Result |
|---|---|---|
| MainWindowFeature | `suites`, `HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1` | 433 of 435 suites passed |
| SettingsFeature | `aggregate` | 140 of 140 passed |
| MenuBarFeature | `aggregate` | 157 of 158 passed |
| HfUI | `aggregate` | 271 of 271 passed |
| Harflow shell | `aggregate` | 124 of 124 passed |
| `macos/build-app.sh` | Debug build | succeeded |

There were no skips. The other user applications open on the Mac during the batch were Notion, Slack, Music, Chrome
and Harflow.

## Resolution of the reds

### MenuBarLayoutTests (test defect, fixed in `0dd2b3ab`)

`givenListAndWorkflowNotices_whenHosted_thenOriginalMessagesRemainAndListNoticePrecedesSections` reported the
notice's maxY as -216 against the Workflows label's 752. The notice's message is a native accessibility cell with a
screen-space frame. The fixture converted that frame as if it were in window coordinates, while it left the SwiftUI
label's frame unconverted. In screen space the notice ends at 806, above Workflows, so the product's order was correct.
The fixture now measures every frame in screen coordinates. No assertion changed. The footer containment checks, which
had passed only because of where the window happened to sit, now check something real. Fable approved this in round 2.
MenuBarLayoutTests passed 12 of 12 in `diag-3`, and the MenuBarFeature aggregate rerun passed 158 of 158.

### WorkflowRunSidebarHostedTests (window interference, no code change)

`givenOnDemandCallsWithDistinctTranscripts_whenRowIsPressed_thenDisplayedTranscriptChanges` failed its 1000×620 dark
case. The feed was not replaced (`SelectedPane.swift:292`), and the selected entry was not found (`:183`).

The suite passed 13 of 13 when run alone with the other applications hidden (`out-mwf-solo`, 49.9 s). The red came
from other applications' windows on the shared screen during the batch.

### ModelPickerStatesHostedTests (two test defects, fixed in `0cab4b27` and `46b964c0`)

**In the batch** the suite passed 21 of 22. Its only red was the `recent-editing` case of
`givenMountedRepositoryTargets_whenTheOriginalPointIsClicked_thenOnlyThatTargetActivates`. The failure detail
recorded `windowNumberAtPoint=292` against `popoverWindowNumber=2594`, so a foreign window owned the click point. That
is the same interference as above.

**Solo runs 1 and 2** (minimal applications) failed differently. Every lookup of popover content through accessibility
returned nothing, and the listing-state test waited until the 300 s partition timeout.

- **Cause:** the suite reads SwiftUI accessibility nodes but never enabled `AXEnhancedUserInterface`, unlike about 18
  other hosted suites. It relied on an outside assistive client to switch accessibility on. One was present during the
  batch and during the earlier 22-of-22 run on `de3e83fa`, but none was present in the minimal sessions.
- **Fix (`0cab4b27`):** a recursive scoping trait, `.accessibilityEnhancedUI`, saves, enables and restores the setting
  around every test case, including on a thrown error. No assertion changed. Fable approved it in round 2.

**Solo runs 3 and 4** (15:18 and 15:28) ran none of the tests. The AppKit host's activation self-test failed
(`active=false key=false`) because the screen was locked.

- At 15:15:52 the idle screen saver had locked the session. WindowServer then allowed only loginwindow to come to the
  front.
- **Missed-lock cause:** the pre-run check read only `IOConsoleLocked`. That value stays false during the 900 s
  password grace period, so the check missed the lock. `CGSSessionScreenIsLocked` would have shown it.
- **Consequence:** solo runs 3 and 4 never exercised the `0cab4b27` fix.
- **Change:** the pre-run checks and the batch watchdog now refuse or stop when any of these is true: `IOConsoleLocked`,
  `CGSSessionScreenIsLocked`, or a running `ScreenSaverEngine`. Each run also keeps the user session active for its
  duration.

**Solo run 5** (on `0cab4b27`, 16:32–16:33) activated the host and passed every accessibility lookup that solo runs 1
and 2 had lost. It passed 21 of 22.

- **Failure:** the `defaultTag` case of the listing-state test at `:200` and `:202`. The Model field's hint was
  "Loading suggested models…", and the model-note element was present; both are expected absent.
- **Cause:** a race in the test.
  - The view model reads the model listing asynchronously, and the view restarts that read when it appears.
  - In scenarios that expect no note, the test waited only for the popover's "Harness" text and one presented frame, so
    its assertions could run before the read finished.
  - The product clears the loading note once the read finishes.
- **Fix (`46b964c0`):** in the no-note branch, the test waits for the listing phase to leave loading before it asserts.
  No assertion changed. Fable reported no blocking findings in round 1.

## Closing run

On `46b964c0` (17:34–17:36), ModelPickerStatesHostedTests passed 22 of 22 when run alone (`out-mwf-solo6`, 44.5 s),
with no skips.

- The host activated (`active=true key=true`).
- The screen stayed unlocked before and after the run, and the lock watchdog did not fire.
- Before and after the run, Finder, Claude and Fork were visible, and Fork was frontmost.

Together with the batch, this means every suite in the stage-4 batch has passed on committed source:

- MainWindowFeature: 433 suites in the batch, plus WorkflowRunSidebarHostedTests and ModelPickerStatesHostedTests
  when run alone;
- MenuBarFeature: 158 of 158 on the rerun;
- SettingsFeature, HfUI and the Harflow shell, as above.

The test-only fixes made after the batch touch only test code in MainWindowFeature and MenuBarFeature.

## Open items

- **Owner visual pass:** the items listed in `HOSTED-BATCH-stage4.md`:
  - the "Harflow · Runtime setup" top bar on every gate;
  - the Harnesses block indents and panel padding (F4);
  - the popover runtime blocks and note;
  - the running row's clock and the Workflows position;
  - the question card states;
  - the Notifications row divider.
- **Manual checks:**
  - answered-question banners are removed from Notification Center;
  - clicking a question banner opens its Needs you item;
  - Open System Settings goes to Harflow's pane;
  - the permission row updates after a change;
  - the notification controls are disabled against a runtime without interaction events.
- **Follow-ups:**
  - InstallRepository state, last-check message, retry and reset have no feature readers (C1-6).
  - The popover's stale copy differs from the main window's (C3-6).
  - `AppModulesRegistryTests.GlobalValuesSnapshot` does not capture the Needs you repository.
  - MainWindowGateTests could move to HfRepository.
  - Dimmed sidebar rows need a VoiceOver cue before M12.
  - The package-standard deprecation warnings remain, including the AppKit host's use of
    `activate(ignoringOtherApps:)`.
- **Hosted interference:** window-placement suites can still fail when other applications' windows share the screen.
  Hosted runs need a cleared screen.
- VoiceOver remains deferred to M12.
- A Harflow Check build from committed source is pending for the owner's review. Stage 4 is not yet accepted.
