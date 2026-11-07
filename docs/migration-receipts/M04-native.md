# M04 native shell and composer

Status: the local strict gates passed on 7b4dbfe (see "Capture gate and sidebar toggle correction"). Owner visual acceptance, aggregate M03/M04 acceptance and 0.0.11 runtime qualification are not established.

## Scope and source

The earlier shell/composer validation used HarflowDesign commit `5b37a3d4d4d06b3d96c517cd384892e1ac6883cf`: `v2/docs/m04-proposal.md`, `v2/docs/approval.md`, `v2/scripts/screens-new-task.js`, `v2/scripts/screens-m04-proposal.js`, `v2/scripts/m04-proposal.js` and `v2/styles/m04-proposal.css`. All 24 proposal states are represented in the synthetic hosted matrix, in Light/Dark at 1280×800 and 1000×620. The corrected matrix passed its strict state, authority and geometry checks; 96 complete native-window captures and eight open-options captures are retained. These are synthetic-view evidence, not ordinary app or provider qualification.

At the time of this earlier validation the selected runtime was exact HarflowMCP 0.0.10; the source now selects 0.0.11, which has not been installed or runtime-qualified. The 0.0.10 isolated qualification is recorded separately in [M03 runtime 0.0.10](M03-runtime-0010.md). Public polling remains selected. This change introduces no watcher adoption, wire contract, provider execution, user-state migration, installation or release.

## Entry and remaining dependencies

| Surface | Implemented behavior | Acceptance limit |
| --- | --- | --- |
| Shell and navigation | Inline New task, a unified navigation/Running/Recent outline with retained pagination, 264-point sidebar and 56-point collapsed rail, retained destinations and appearance | Synthetic native capture, focus/AX and pinned viewport checks passed; the complete package gate remains failed as recorded below |
| Composer | One VM per window; + popover with existing small native scroll chrome; repository/harness/model/access and retained advanced choices | Synthetic submission/state and native read-only regressions passed; no provider launch qualification claimed |
| Submission outcomes | Captured request/runtime/revision, single-flight dispatch, correctable definitive refusal and retained unknown-outcome lock across navigation/Command-N | Unknown never means safe to replay |
| Setup and first listing | Explicit setup/progress/failure states; qualified first-list failure has its own retry | Acquisition remains explicit; tests do not install software |
| Recorded successors | Bounded public direct-successor observation with runtime fencing and separate selected inventory | Recorded tasks only; pending launches and global absence are not established |
| Workflow activity | Exact-runtime complete settlement proof or capability-gated unsettled read | Old native probe success is not proof; aggregate workflow/runtime acceptance remains separate |
| Stored changes | Existing route retained | M05 dependency remains outstanding |
| Statistics cost/effective model | Existing route retained | M10 semantic/coverage obligations remain outstanding |
| Aggregate M03/M04 | No acceptance asserted | Owner gates and remaining dependent features are not waived |

## Verification

Headless Python tooling: 203 tests passed after the synthetic host resource-bundle correction. Eight guarded native packages outside MainWindow passed, totaling 1,552 tests: MonitorCore 462, HfRepository 520, HfUtilities 19, HfCommon 18, HfUI 239, MenuBarFeature 88, SettingsFeature 87 and Harflow 119. The affected consumer packages passed again after helper extraction. The earlier consumer/UI review cycle completed three rounds. The separately authorized correction cycle has completed one fresh final review with no actionable defects. Formatting, strict lint, legacy-name and private-reference guards passed; the seven tracker-owned inputs remain unchanged.

Correction-cycle evidence established and repaired a native prompt editor that accepted input after locking. The owned editor now changes editability in place, guards binding writes and owns its undo history. Native input, retained options, access-menu selection and all approved matrix states passed. The complete window captures include the native sidebar; root view bitmaps alone omit its separately composited content and are not used as full-shell fidelity evidence.

The earlier sidebar baseline checks the actual composer's text-input isolation, restoring the invariant previously exercised by the removed search field. It requires the same native editor to remain first responder after Up, unchanged native/model text, and unchanged nonempty Running and Recent selections. Navigation retains separate unique public AX identity and frame checks. Native button focus is not forced when macOS Keyboard Navigation is disabled. The pinned fixture has Recent viewport top 372 and bottom 61, a 224-point fixed header and 164-point Running allocation, with exact row, adjacency and visibility checks. These values record the reviewed native adaptation; they do not assert owner acceptance or web-pixel equivalence.

The latest complete guarded MainWindow run (`cycle2-full-r2`) completed all 252 partitions and discovered 1,859 test identities. It passed 251 partitions covering 1,852 identities; all three corrected fixture suites passed. All 466 console observations were unlocked. The gate nevertheless failed: `WorkflowScreenLayoutTests` at minimum Light size observed canvas minY 91 against tray AX maxY 95.5, violating the unchanged one-point boundary assertion. This exactly matches the cause-unproven historical observation recorded in [S02](S02.md). Its recurrence is not waived or attributed to M04 without evidence. Failure-context diagnostics are being prepared; no production workflow layout repair is claimed.

The earlier post-refactor Release build and packaged-startup diagnostic passed before the native editor correction; final post-correction Release/bundle validation remains pending. Runtime smoke is explicitly outside this correction cycle. The complete native gate, final delivery and aggregate M03/M04 acceptance remain outstanding.

Working evidence is outside the repository at `/private/tmp/harflow-native-m04-1dzklyrc`. Tracker-owned migration plan/session files and five M01 receipts remain excluded from this work.

## Sidebar icon fidelity correction

Owner review identified SF Symbol substitutions in the native sidebar. The sidebar now uses the ten exact SVG sources from the approved design commit above, with transparent 24-point vector PDF exports vendored in the feature resource bundle. Source bytes and recorded PDF hashes were independently verified. Native loading explicitly selects the packaged application resource bundle and caches its template images; standalone tests use the module bundle. This avoids command-line SwiftPM's uncompiled asset-catalog copy and adds no runtime SVG parser or sibling-checkout dependency. Navigation actions and accessible control labels are retained.

Earlier guarded offscreen icon-load attempts did not complete: its first attempt stopped on the unchanged process-probe timeout under heavy load; the PDF attempt was interrupted when the owner requested validation pause, before test execution. Native asset loading, post-icon UI captures, final Release packaging and the complete post-icon package gate remain pending. The preceding full-run result predates this artwork correction.


## Owner-approved centered composer and sidebar amendment (2026-11-06)

The current source targets HarflowDesign `9d64bfda7bed735d42c761c3149516c7f3e6ca01`,
`v2/docs/m04-centered-composer-proposal.md` and the six
`m04-proposal/amendment-*` routes. The owner approved the centered composer,
then requested normal sidebar row spacing, one scroll area for navigation,
Running and Recent work, and the existing small native overlay scrollbar.
The design commit is pushed. Native source preserves the owned prompt editor,
measures wrapped text from one through six lines (26–136 points), and centers
the complete heading/composer/outcome/help group with a top-safe overflow path.
A single native outline supplies the shared sidebar scrolling and retains
native selection, reconciliation and revision-qualified history visibility.

Earlier icon-focused checks passed native loading and the Release bundle's ten
PDF hashes; the later focused matrix still failed collapsed-control AX names
and one capture's foreground qualification. The collapsed labels were corrected,
but have not been rerun. The earlier full 251/252 result and its workflow layout
failure predate these current composer/sidebar changes and remain historical
evidence only. Existing two-outline geometry fixture expectations require precise
updates to the newly requested single-outline design; their strict assertions
have not been waived or removed.

The owner requested committing and pushing both this implementation and the
other session's completed contract-fixture updates before full UI validation.
The 217 changed contract fixtures match the canonical HarflowMCP checkout byte
for byte. This does not select or qualify a newer production runtime: 0.0.10
remained selected at that point; 0.0.11 was selected later. Full post-change strict validation, native visual acceptance
and aggregate M03/M04 acceptance remain outstanding. Foreground testing is held
at the owner's request. Runtime smoke is explicitly out of scope.


Post-correction pre-commit verification: the guarded diagnostic compiled the
complete MainWindowFeature test target and passed all 13 discovered identities
in ComposerPromptEditorTests (7), SidebarM04PresentationTests (2) and
SidebarUnifiedScrollTests (4). This is a selected headless diagnostic, not the
complete package gate. The width-change regression reproduced AppKit automatic
container tracking overriding an explicitly proposed width; the editor now sets
container width explicitly during both measurement and layout. Empty, wrapped,
re-expanded, trailing-newline and Unicode layout checks pass without weakening
the assertions. The two-line fixture now correctly expects 48 points.

The final bounded review (round 3 of 3) found a missing test row index and an
identity comparison using different task inventories; both were corrected.
The subsequent compile also required main-actor isolation on the new hosted
fixture helper. Runner unit tests pass (119), the complete Swift formatting
check reports zero files requiring changes, and strict lint reports zero
violations. Legacy-name/private-reference guards and protected-input hashes
pass. The new foreground suites are registered in the runner's exact AppKit
host allowlist. No foreground UI or runtime smoke was executed for this
amendment. Release packaging and full strict UI validation remain pending.


## Capture gate and sidebar toggle correction (2026-11-06)

This owner-approved bounded cycle ran under the second macOS account sharing this workspace, with the Xcode 26 toolchain. A reboot erased the earlier scratch evidence, so earlier results in this receipt cannot be rechecked. Current evidence is in the workspace's `.claude-work/mac/` directory, outside the repository.

### Results on 7b4dbfe

| Check | Result |
| --- | --- |
| MainWindowFeature, `--mode suites`, with `HARFLOW_M04_CAPTURE_DIR` and `HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1` | Passed: 259/259 suites, 1,911/1,911 tests, 104 window captures, no capture errors. Peak one-minute load 8.2 |
| `SidebarUnifiedHostedTests`, 20 fresh processes | Passed 20/20 |
| `macos/build-app.sh` (build only) | Passed |
| Python runner and CI tests | Passed: 235 tests, 30 subtests |
| Format, strict lint, legacy-name and private-reference guards | Passed |

The other eight packages passed their aggregate gates at c53a6f7 (1,552 tests): HfCommon 18, HfUI 239, HfUtilities 19, HfRepository 520, MonitorCore 462, MenuBarFeature 88, SettingsFeature 87 and Harflow 119. Later commits change only MainWindowFeature, documentation and fixtures, so these were not rerun.

### Earlier capture failure: not reproduced, cause unknown

`/usr/sbin/screencapture` failing with "could not create image from window" at `composer-invalid-light-1280x800` did not recur in three undisturbed focused runs or either full gate. The same text is printed for a nonexistent window number, so it does not identify a cause. The capture assertions are unchanged. This is an absence of recurrence, not a fix.

Three earlier focused runs are void because of accidental mouse input. Two later attempts did not execute: leftover diagnostic load processes stopped the builds, and a separate macOS permission prompt held the foreground and blocked host activation. The prompt shows that an unrelated system dialog can block foreground fixtures.

### Sidebar scroll test

`SidebarUnifiedHostedTests.swift` failed its end-marker visibility check in one full gate and 2/10 focused runs on c53a6f7, and in 0/10 runs under CPU load. The test scrolled once while row presentations were still settling. Document height changes transiently during entry presentation; the end marker moved between y=2052 and y=2240, and failing viewports stopped at origins 831.9 and 1855.4. The fixture now waits for settled geometry, scrolls once and asserts the result without retrying. No product scrolling defect was shown, and this transient height behavior remains in the product.

### System sidebar toggle removed

The owner reported two sidebar toggles. `.toolbar(removing: .sidebarToggle)` on the split view did not remove the system item. It is now applied to the sidebar column before `navigationSplitViewColumnWidth`.

| Probe placement (`NSHostingController`) | Sidebar width | System toggle | Title midX, 1000-point window |
| --- | --- | --- | --- |
| On the split view | 264 | Present | 636.75 |
| On the column, before the width modifier | 264 | Absent, also collapsed and re-expanded | 500.25 |
| On the column, after the width modifier | 140 | Absent | 500.25 |

Removal also removes the split-view separator item, centres the title on the window and lowers the sidebar card about 6 points. The owner accepted this on real before and after captures on 2026-11-06; tests pin the title within 16 points of the window centre. The toolbar check depends on SwiftUI's private identifier `com.apple.SwiftUI.navigationSplitView.toggleSidebar`, so a positive-control test fails if it is renamed. Before the fix, the check failed in all 96 matrix cases and at 3 re-expansion checkpoints.

### Review and limits

Plan and code each ran the three-reviewer loop for two rounds, over `705ceb7..7b4dbfe` for code. All code findings were fixed or adjudicated. Accepted findings strengthened silent waits, corrected stale 0.0.10 statements and added the changelog entries.

- The real SwiftUI `Window` scene was not measured: the scratch probe opened no window in that shape, and no development app was launched. Owner visual review of the real window closes this.
- 0.0.11 installation, execution and runtime qualification remain pending and were out of scope. ST05 was not started.
- CI on `main` previously failed in `macos/build-app.sh` on Xcode macro enablement for Dummyable, Mockable and SwiftEnvironment. The local build passed. CI was not rechecked, and macro trust settings were not changed.
- Captures are synthetic fixture evidence. Passing gates are not owner acceptance of M04.

## Real window review and composer padding (2026-11-07)

The owner reviewed the real `Window` scene in an isolated copy of a Release build at `04afd56`: unique bundle identifier, no URL schemes, a scratch HOME seeded through the production `ManagedRuntimeInstaller` with local acquisitions, and synthetic task state. Notification flags were set to typed `false` through launch arguments, which also settles the open question in the S02 fixture receipt. The app still writes its window frame to a unique preference domain in the real account, because macOS does not redirect preferences to the scratch HOME; that domain is removed afterwards. This run does not qualify runtime 0.0.11.

- **Title position: accepted by the owner.** In the real window the title sits over the content column, about 135 points right of window centre at 1440 points wide. This corrects the statement above that removing the system toggle centres the title on the window, which holds only for the `NSHostingController` probe and the hosted tests that pin it.
- **Composer padding: changed and accepted by the owner.** Inner padding now follows `.hd-composer` in HarflowDesign `v2/styles/bundle.css`: 12 points top and right, 8 bottom, 16 left. The owner viewed the result in the real window. The prompt width expectation moved from 688 to 692 with the same tolerance.
- **Not yet given:** explicit owner verdicts on the single sidebar icon and on the sidebar card position. M04 is not accepted.

Opus, Codex and Vibe each approved the padding diff with no findings to fix. Vibe could not open the design checkout and checked the CSS mapping against values supplied in its prompt; Opus read the design rule directly.

Focused runs through the guarded runner passed for the six suites hosting the composer: `CenteredComposerHostedTests`, `NewSessionComposerHostedTests`, `QualificationHostedTests`, `AccessOptionRowTests`, `M04StateMatrixHostedTests` and `NativePreferenceCaptureTests`. Format, lint with installed SwiftLint 0.57.1 rather than CI's pinned 0.63.2, and both guards passed. The strict package gates were not rerun for this change.

`M04StateMatrixHostedTests` failed once before passing. At a one-minute load near 30, with the isolated app open, it recorded 5 issues: `NSApp.isActive` false, `screencapture` exit status 15 twice and two missing PNG files, with no layout assertion among them. The same unchanged suite then passed twice at a load near 9, with no issues and 208 captures each, the isolated app still open. Load is a plausible factor but was not isolated, so the cause of that failure, like the earlier capture failure above, remains unknown.
