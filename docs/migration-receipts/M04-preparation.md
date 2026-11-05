# M04 — shell and new-task entry preparation

Status: preparation only. No M04 production implementation or acceptance is established.

The owner-approved 2026-11-05 stage amendment permits D2B delivery and independent
M04 preparation. It permits implementation only where the actual prerequisites and
approved designs are satisfied. The workspace session brief requires M03 and
approved shell/composer states before M04 implementation. No qualified production
entry slice is currently established; this record does not waive that prerequisite.

## Immutable references

- HarflowMac D2B implementation: `3b0e0c4d516b5e8d655cfe8a5c024fe5c7cb0eb8` (local only), based on
  `cd80fd1df1162953f5749bc3dc03ac4345e83668`. Its bounded validation and open
  acceptance limits remain in the [D2B receipt](M03-D2B.md).
- HarflowDesign inspected head: `227da87ade53fd30af7a3e28776258c1bd72c72c`.
- Approved core composer template: `v2/scripts/screens-new-task.js`, last changed
  at `24958cfb155cc1149b527aba725d90931068abd0`, contained unchanged in approved
  `3643d083700be4032c93237813b573d04bab6ab1`. States: `new-task/default`,
  `new-task/harness-menu`, `new-task/sidebar-collapsed`, each Light/Dark.
  Browser approval does not establish native adaptation or pixel fidelity.
- The v2 approval, screen inventory and migration coverage ledger remain the
  authority for presentation. D2B's scoped approval does not approve M04.

## Entry matrix

| Surface | Existing approved direction / retained behavior | Remaining entry gate |
| --- | --- | --- |
| Navigation, Running/Recent and collapsed rail | Three approved core states show the flat sidebar and 56px browser-reference rail | M03 entry; G01 native chrome, footer, window and keyboard/focus/AX/Reduce Motion adaptation |
| Basic composer | Approved repository, harness/model and access controls | M03 entry; G01 native placement/focus; G02 qualification, validation, refusal and unknown-start states |
| Harness/model menu | Approved menu direction; engine-reported capability cells remain authoritative | G-HARNESS qualification and truthful unavailable/unsupported presentation; no inferred harness guarantees |
| Repository choices | Existing VM exposes up to five recent distinct task repositories and refreshes qualification on changes | Preserve repository identity and per-repository options; approve empty/invalid/permission and stale-result presentation in G02 |
| Advanced options | Existing effort, turn limit, caller approvals and qualification/enforcement behavior provide evidence | G-NEWTASK-ADVANCED and G02 remain Proposed; scope and missing states require owner/design decisions |
| Running/Recent history | Flat presentation is accepted visually; public reads and identity/authority remain required | G-HISTORY paging, retention, reconnect/unavailable and selection/successor treatment; no restoration of removed search/filter controls |

The proposed G01/G02 briefs are recorded in [M01 design](M01-design.md). No
approved native adaptation receipt was found. Required missing states block their
dependent composition; the inventory does not turn Proposed scope into approval.

## Existing safety seams to preserve

`NewSessionVM` already owns useful boundaries in
`macos/HfFeatures/MainWindowFeature/Sources/MainWindowFeature/NewSession/NewSessionVM.swift`:

- `canStart` requires qualification readiness, nonempty backend/repository/message,
  valid options and no start in progress.
- `didChangeRepo` and backend/model changes refresh or invalidate discovery and
  qualification; disappearance cancels qualification/model work.
- Start captures a request, requalifies, requires a selected runtime, compares the
  current request with the captured request and checks that start is still active
  before dispatch. Success routes the returned task identity.
- Recent repository choices retain their actual paths. Model discovery and
  qualification must not let stale responses overwrite a newer selection.

These are behavioral requirements for later composition, not new authority or an
approval to change execution semantics. The native engine boundary remains public
`harflow-ctl`; missing operations are not permission for private reads or MCP.

## Combined material gates

1. **M03 entry:** finish its required local gates and qualify the intended exact
   runtime or obtain an explicit alternative. The selected runtime remains 0.0.7;
   intended 0.0.8 selection/qualification and real managed-runtime smoke remain
   unperformed/outside authorization. A D2B commit alone would not close M03.
2. **G01:** approve native shell/window/sidebar/footer and adaptive interaction
   states with exact immutable commit/path/state references. Preserve the existing
   1000×620 supported minimum as evidence; D2B sizing is not blanket shell approval.
3. **G02:** decide retained advanced-composer scope and approve qualification,
   validation, refusal and unknown-start presentations. Do not silently remove
   authority controls to fit the basic specimen or imply unsupported enforcement.
4. **History dependencies:** approve the G-HISTORY states before the dependent
   Running/Recent failure and paging flows are implemented.

Once these entries are satisfied, the smallest proposed production slice is core
navigation/rail/basic composer using the pinned approved references and existing
qualification/stale-response fences. Advanced and history-dependent flows remain
blocked until their own required states are approved.

No production code, fixture/runtime pin, steering consumer, tracker, sibling
repository, installation, acquisition, live runtime/provider or release state was
changed by this preparation. Owner, runtime and performance acceptance remain open.

## Subsequent approved design and runtime evidence — 2026-11-05

This update supersedes the earlier design-unapproved and runtime-unperformed
snapshots only within the scope below. It does not start M04 production work.

The owner approved HarflowDesign `5b37a3d4d4d06b3d96c517cd384892e1ac6883cf`,
`v2/docs/approval.md` and `v2/docs/m04-proposal.md`; implementation references are
`v2/scripts/screens-m04-proposal.js`, `v2/scripts/m04-proposal.js` and
`v2/styles/m04-proposal.css`. Approval covers all 24 `m04-proposal` states in
Light/Dark: shell, shell-collapsed, shell-narrow; composer-loading, composer-ready,
composer-unqualified, composer-invalid, composer-starting, composer-refused,
composer-unknown; advanced, advanced-closed; history-empty, history-loading,
history-older, history-error, history-reconnecting, history-retained;
runtime-checking, runtime-install-required, runtime-update-required,
runtime-installing, runtime-failed, runtime-listing. The final approved direction
includes the bottom-left + task-options popover and slim scrollbar using the
existing tertiary token at 72%. This approves visual direction and local interaction,
not native pixel fidelity or production capability/persistence acceptance.

The [runtime receipt](M03-runtime-qualification.md) records exact 0.0.8 scratch
qualification and same-PID rendered initial/refresh proof, together with the failed
controller cleanup observation and separate completed teardown evidence. Production
selection remains 0.0.7. Final source review resolved the launcher-read finding; all eight headless
packages (1,527 tests), Release/bundle checks, and the final MainWindow run
(246 suites, 1,814 tests) passed. The remaining-consumer inventory still requires an
explicit disposition of successor completeness and unsettled/live workflow capability fencing, preserving older settled reads;
statistics/stored-changes dependencies are not implicitly owner-deferred.

No M04 production implementation, aggregate M03 acceptance, production pin change
or owner performance acceptance is established by these updates.
