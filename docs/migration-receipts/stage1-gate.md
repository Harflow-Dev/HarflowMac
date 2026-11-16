# Stage 1 gate

Status: run 1 complete on 2026-11-16, not passed. One regression (`ActivityFeedReadingGeometryTests`) and one earlier failure (`SidebarNativeParityBaselineTests`) are being fixed; this receipt is updated with the targeted rerun. Owner sign-off pending.

## Scope (owner decisions of 2026-11-16, relayed by the coordinator)

- The full MainWindowFeature suite through the guarded runner, in the owner's idle window with the Mac unlocked and idle.
- A fresh Harflow Check build from HEAD: identifier `dev.harflow.mac.check`, no URL types, ad-hoc signature, `codesign --verify --strict`.
- The runtime seeding and the public reads the app makes, against a scratch HOME. The app launch is skipped: no development build is launched, and nothing writes to `~/Library/Preferences` or the real `~/.harflow`. The owner's own stage-1 look with the Check copy covers the real launch.
- A suite rerun only for load or lock failures and only with at least 35 minutes of the idle hour left.

Evidence is outside the repository under `.claude-work/mac/gate-s1/` and `.claude-work/mac/smoke-s1/` in the workspace.

## Run 1

HEAD `da8e3b90c2e891978c0a1ed3b12aa691784991ee`, clean tree. Started 06:23, suite finished 06:56, gate finished 06:58 (WIB). Script `gate-s1/gate-s1.sh`, log `gate-s1/run1/gate.log`.

| Check | Result |
| --- | --- |
| Full MainWindowFeature suite (`--mode suites`, guarded runner, scratch HOME) | Failed: 385 of 390 suites, 3,654 of 3,687 tests passed |
| swiftformat lint, `swiftlint --strict`, legacy-name and private-reference guards | Passed |
| Runner and CI Python tests | Passed (696 tests, 30 subtests) |
| `macos/build-app.sh` | Passed |
| Harflow Check copy | Identifier `dev.harflow.mac.check`, URL types absent, `codesign --verify --strict`: valid on disk, satisfies its designated requirement |

### Suite failures

| Suite | Failure | Classification and evidence |
| --- | --- | --- |
| `NewSessionComposerHostedTests` | scroller style check (`NewSessionComposerHostedTests.swift:121`) | Known: this account's scroll bar setting |
| `WorkflowRecoveryFormTests` | no issue recorded in the full run | Load: passed on an immediate focused rerun at HEAD (`gate-s1/run1-focused`) |
| `WorkflowScreenLayoutTests` | canvas ended 3.5 pt into the step tray | Load: passed on an immediate focused rerun at HEAD |
| `ActivityFeedReadingGeometryTests` | after earlier history is published while paused, the test's measurement-generation signal does not advance (`ActivityFeedPagingGeometryTests.swift:221`) | Regression from `feac4e8` (activity feed arrival fade in Core Animation): passes at `4f695ec`, fails at `feac4e8` and HEAD, each built from a clean export (`gate-s1/bisect`). Being fixed through the bug-fix workflow |
| `SidebarNativeParityBaselineTests` | sidebar accessibility signatures differ from the stored baseline | Earlier than this stage's last commits: already fails at `4f695ec`. Being traced to its commit |

No full rerun: the suite finished with 27 minutes of the idle hour left, under the 35-minute threshold.

## Runtime seeding and public reads

Kit `.claude-work/mac/smoke-s1`, built from a `git archive` of HEAD `da8e3b9`; evidence `smoke-s1/evidence/`.

- Inputs: the 0.0.14 PyPI JSON (`7cc53b17…aad9f6`), the production specification (`56835546…190075`) and the engine wheel (`76f98084…3f39`, 1,393,614 bytes) match the M03 0.0.14 receipt; the interpreter and 29 dependencies match the specification by size and SHA-256.
- A scratch harness linking HEAD's MonitorCore drove the production installer in scratch HOME G (mode 0700, scrubbed environment): fresh 0.0.14 install 32 acquisitions and 9 subprocesses, then check and offline prepare 0 and 6 each, same generation (`0.0.14-cf843ca7…-9F0689E1-…`). Four synthetic tasks were seeded with the generation's own Python.
- `public-reads.sh gate-run1`: `version-info` (0.0.14, contracts v1, `backend-models.v1` advertised), `list` twice (the same four tasks; the raw outputs differ only in the responding server's pid and duration), `status` for each task, `task-events` for one task (empty page; the seed has no normalized events) and `backend-models` for six harnesses (`not_installed`, since PATH holds system directories only). All 14 exited 0. The eight task record files hashed identically before and after; the engine created its own index and lock files in the scratch state root. The owner's preference files were unchanged by size and modification time.
- Not exercised: the app launch (owner decision), `status --observer-parent`, and a poll-driven second list (the second list ran directly).

## Owner sign-off

Pending the fixes and the targeted rerun below.
