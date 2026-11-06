# HarflowMac implementation handoff

Updated 2026-11-06. Owner requested that Codex pause all implementation and leave this handoff for Claude. No implementation, test, or review job from this session remains active. The desktop has been released. This document does not authorize new execution or publishing.

## Starting point

- Repository: `HarflowMac` in the shared Harflow workspace; use this primary checkout, no new branch or worktree without authorization.
- Current HEAD: `705ceb7befcbf7a7e8fc013b95e7269bac5cf39b` (also the last observed upstream HEAD).
- The current M04 correction and managed-runtime 0.0.11 adoption are **uncommitted**. Preserve the complete dirty tree, including untracked tests.
- Read workspace `AGENTS.md`, repository `AGENTS.md`, `macos/AGENTS.md`, applicable package guidance, and migration documentation before continuing. Migration checklist entries are not owner acceptance.
- No commit or push was made during this correction cycle. No new Mac push, release, signing, app installation, provider calls, or backend/MCP registration is authorized by this handoff.
- Runtime smoke is explicitly **out of scope** for the current validation task. Do not launch a development app against real user state.
- Ask for a fresh unlocked, awake, untouched desktop window before foreground testing; the previous reservation has ended. Do not change system lock preferences or stop other sessions' processes.

## Preserve these seven unrelated inputs

Do not edit, stage, revert, or include these in a task commit:

- `docs/migration-plan.md`
- `docs/migration-sessions.md`
- `docs/migration-receipts/M01-checks.json`
- `docs/migration-receipts/M01-contracts.md`
- `docs/migration-receipts/M01-design.md`
- `docs/migration-receipts/M01-native.md`
- `docs/migration-receipts/M01.md`

Their starting hashes are in the local evidence directory's `evidence/correction3-start.json`. They were verified unchanged after the last full run. Other sessions own these migration inputs; inspect current ownership before touching any additional files.

## Approved design and implemented behavior

Design source: sibling `HarflowDesign`, approved and pushed commit `9d64bfda7bed735d42c761c3149516c7f3e6ca01`, `v2/docs/m04-proposal.md` and the referenced M04 proposal states. Verify hosted deployment separately before claiming the website reflects that commit. The prototype is presentation authority; public engine contracts control semantics.

Current native changes include:

- New task heading, composer, outcome and help form one centered layout. The prompt grows with actual visual lines from one through six, then scrolls. Editor line-height/cap assertions remain strict.
- Sidebar navigation, Running and Recent share one virtualized body scroller; brand/footer remain fixed, with the existing small overlay scrollbar. Preserve exact approved row heights, section spacing and keyboard behavior.
- Exact design navigation PDF icons are retained; ten packaged PDFs were checked byte-identical to source.
- Shared selection normalization prevents destinationless rows from being selected by a nil destination.
- History presentation admission waits for actual row animation/height/generation settlement; raw diagnostic evidence confirms premature geometry is suppressed. Preserve identity and stale-generation guards.
- Read-only native editor behavior and public placeholder metadata are covered by hosted fixtures.

Most implementation is in `macos/HfFeatures/MainWindowFeature` (NewSession, Sidebar and corresponding tests). The immutable reviewed snapshot lists all 40 relevant files; use it to distinguish task files from protected inputs.

## Latest menu correction: verified

`SidebarNavigationRail.swift` now uses an inline native `Picker` inside the existing appearance `Menu`, bound through the existing single `didSelectAppearance` handler. The previous painted checkmark did not set native menu-item selection state.

`SidebarNavigationRailFocusedAXHostedTests.swift` and `SidebarRailMenuTrackingProbe.swift` verify:

1. Exactly one named, enabled appearance menu and an allowed modern public show-menu action.
2. Exactly three owned native menu items: Light, Dark, System; initial System is natively on and the others off.
3. One allowed public Light press, followed by actual VM Light selection and exactly one callback.

AppKit's modern `accessibilityPerformPress()` returned **false while delivering the deferred action successfully**. The test records this Boolean truthfully; success requires the exact eventual semantic effect, not a fabricated true acknowledgment. Do not add an alternate action or direct VM call.

Native menu tracking owns a nested main run loop. The test arms a selector-based tracking notification observer and a weak timer in default/event-tracking modes **before** showing the menu. It only retains/cancels an exactly matched owned menu. No private APIs, off-main AppKit, arbitrary sleeps or global menu cancellation. Unknown ownership fails closed under the guarded runner's process bound.

Earlier native outline crashes came from Swift's specialized `NSAccessibilityTable` array bridge. Tests erase the outline to `any NSAccessibilityProtocol` before both reading and setting selected rows, preserving the real public accessibility route. Do not restore the crashing specialized bridge.

## Latest strict validation: not green

The final run completed all packages below. Its source hashes still matched the reviewed snapshot afterward.

| Package/check | Observed result |
| --- | --- |
| HfUI aggregate | 239 tests passed |
| MenuBarFeature aggregate | 88 tests passed |
| SettingsFeature aggregate | 87 tests passed |
| MainWindowFeature suites | 1,909 discovered identities; 258 of 259 suites passed; overall failed |
| Focused corrected menu diagnostic | Passed |
| Affected headless MainWindow fixtures | 30 identities passed |
| MonitorCore aggregate | 462 tests in 68 suites passed |
| HfCommon / HfUtilities / HfRepository | 18 / 19 / 520 passed |
| Harflow app-shell aggregate after final product fix | 119 tests passed |
| Runner / release Python checks | 128 / 52 passed |
| Release build and bundle validator after Picker correction | Passed |
| Format / strict lint / legacy and private-reference guards / diff check | Passed |

The sole final MainWindow failure was `M04StateMatrixHostedTests`, for capture `composer-invalid-light-1280x800`:

- `/usr/sbin/screencapture` returned exit 1: `could not create image from window`.
- `M04NativeWindowEvidence.swift:34` asserted the nonzero exit; line 35 asserted the missing PNG.
- Do **not** omit that state, weaken these assertions, or label the full suite green.
- The state matrix continued through its remaining cases. No other suite failed. Sidebar/menu/composer/read-only/focus behavior passed in the full run.
- All 484 console observations were unlocked during the 981.4-second remaining-package run. A lock is not supported as the explanation for this capture failure.
- Root cause remains unresolved: investigate exact owned-window visibility/readiness and capture lifecycle before changing implementation. A later isolated pass alone would not erase this failed full-run result.

The final independent review was clean: round 3 verified the patch SHA and all 40 file hashes, including the four files changed since round 2. The existing bounded correction/review budget is **3/3 used**. Do not silently start a fourth correction/review cycle; agree a new bounded scope with the owner if needed. Review does not substitute for the failed validation gate.

## Local evidence and reproducibility

Local scratch directory (temporary; do not assume it survives cleanup):

`/private/tmp/harflow-native-m04-1dzklyrc`

Useful entries relative to that directory:

- `evidence/correction3-review3.json` and `.patch`: final immutable 40-file review snapshot and hashes.
- `evidence/correction3-full-r1/remaining-gates.json`: final four-package status.
- `evidence/correction3-full-r1/MainWindowFeature/manifest.json`: canonical per-suite result/identity evidence.
- `evidence/correction3-full-r1/MainWindowFeature/04-MainWindowFeatureTests.M04StateMatrixHostedTests.stderr.log`: two capture assertion failures.
- `evidence/correction3-full-r1-captures/composer-invalid-light-1280x800-window-capture.log`: native capture error.
- `evidence/correction3-full-r1-console.json`: newline-delimited console observations, not a single JSON object.
- `evidence/correction3-menu-r3b-captures/rail-menu-tracking.json`: native initial states, ownership, action acknowledgment; final VM effect is asserted in the test results.
- `evidence/correction3-picker-packaging-results.json`: app-shell, Release build and bundle checker all exit 0.
- `evidence/correction3-release-assets.json`: ten packaged PDF comparisons.
- `evidence/correction3-final-format.log`, `correction3-final-lint-r2.log`: final successful source checks. The earlier lint run found zero violations but exited on sandbox cache permissions; the cache-permitted rerun exited 0.
- `CURRENT_STAGE.md`: historical checkpoints; later entries supersede earlier pending/running statements. It is not a clean acceptance receipt.

Scratch helpers `focused-validation.py` (diagnostics only), `quiet-validation.py` (console/awake monitoring), and `remaining-ui-gates.py` exist there. Inspect before reuse. The last invokes the unchanged production package runner serially in-process; it does not relax the runner. Scratch compiler wrappers cap compilation at two jobs without editing product scripts.

Use repository `scripts/test-swift-package.py` for package gates; bare `swift test` exit is insufficient. MainWindow uses `--mode suites` and `HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1`; other packages use aggregate, with `HARFLOW_NATIVE_BENCHMARK=1` as required. Never run native package builds/tests concurrently. New runs need fresh evidence output paths. Preserve strict event/identity coverage, timeout and XCTest-silence checks.

## Managed runtime 0.0.11 adoption

Owner authorized selecting published HarflowMCP **0.0.11** and canonical consumer contracts. Source pin, provenance, source/release gates and exact test expectations are updated in the dirty tree.

Verified release commit: `6195e619499003301e4b20bacc3da86b5dbe371a`.

- Wheel: 1,368,241 bytes; SHA-256 `8ec421d1e21894f0fc9504f2d928eb02cef7c1d245fecd6fc5ba69204a346dfc`.
- Source archive: 3,501,141 bytes; SHA-256 `bdf02ad4a28dbc5d17c02e01a5006613e877171e246a873906bf3f2fa1641c4a`.
- All 293 already-vendored contract files matched the public source archive byte-for-byte; no fixture rewrite was needed. Manifest SHA-256: `cd58a5ef8bae565513669dcf4d4ac9179ea327d5093de4461806d7be8dae1873`.
- Managed spec was generated from the verified source lock inputs with a frozen offline export; the 29 dependencies and pinned Python 3.13.16 were unchanged.
- Release workflow 42202239721 and exact-head main checks 42192019385 were observed successful. Duplicate tag checks 42202239575 were still in progress when last checked; do not claim all remote runs succeeded without refreshing.
- Actual installation/execution and exact-runtime qualification of 0.0.11 remain **pending**. Static artifact, fixture and bundle checks are not runtime qualification.
- Bundle checker uses `--check-packaged-startup`, which exits before normal app/runtime initialization; this was not runtime smoke.

See scratch `RUNTIME11_ADOPTION_PLAN.md` and sibling engine release documentation. Do not edit the engine checkout or adopt its dirty changes without ownership coordination. HarflowMCP remains canonical public-contract owner until accepted migration transfer; the Mac consumes public `harflow-ctl`, never persistence or agent-facing MCP.

## ST05: accepted future scope, not implemented

The owner accepted native steering-consumer work through public contracts as prerequisites permit. It is only planned here; do not report it as implemented or qualified.

1. Typed MonitorCore conversation prepare/send/control adapters, fixture tests, fresh capability handshake per operation. Preserve 64 KiB request / 32 KiB text limits and UUID/witness on unknown outcome; no automatic replay. Keep legacy messaging separate.
2. Explicit qualified-profile enrollment and repository adapter. Protocol capability is not profile qualification; never silently drop selected model, effort or grants to fit a matrix.
3. Existing transcript/composer/status adaptation. Clear only the captured submitted draft after accepted admission; unknown outcome remains locked and recoverable explicitly.
4. Explicit workflow/builder commit action, never implicit graph advance or Apply/Save.

Semantics to preserve: unlimited explicit messages with one finite response each; execution/attempt counters separate; retention limits are not quotas; Queue is FIFO at whole-response boundaries; Now only for qualified streaming; tool-interruption-unqualified remains truthful. Reserved `workflow-steering-poststart.v1` does not enable production worker replacement.

## Recommended first action for Claude

Confirm this pause/handoff scope with the owner, inspect the current dirty state and immutable hashes, and propose a bounded capture-readiness investigation. Retain the completed functional fixes and clean review. Do not begin runtime smoke, publish, or claim M04 accepted. Any new source correction needs affected post-fix validation and an explicitly agreed review scope; the previous cycle is exhausted.
