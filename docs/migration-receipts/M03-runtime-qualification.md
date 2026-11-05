# M03 — exact candidate runtime qualification

Status: bounded scratch-runtime and functional app evidence reviewed. The final
source passed the post-repair guarded MainWindow gate on 2026-11-06. No aggregate M03 acceptance,
production runtime selection, M04 implementation or owner performance acceptance follows.

## Immutable inputs and correction

Mac base: `dadef6e465a0856d2262d5694c6a76c9fb231f15`. The accompanying
[checks](M03-runtime-qualification-checks.json) preserve immutable input identities,
artifact hashes and normalized results. Raw reports and investigation tools remain
outside the product repository; artifact descriptions are relative to the temporary
evidence root and contain no personal home paths.

The exact released HarflowMCP 0.0.8 input is
`f304a65d9de948dfcba4c0c27c3d04f7f90971c8`. The wheel SHA-256 is
`f7aadeb9e4d1e131b3da05efa5f3f000eb4945e1c72dd4b0a002d27bb5f8472e`;
the canonical contract manifest is
`6e742e1966d2b48afbfc80268b19f27da1e3f75f046f5683a35fc671228c7ce1`.
Candidate specification file SHA-256 is
`03a3c350455c337e562cc74637269acdbe9a9fc8a0f3b0051eaa46d3d6cda4ad`;
its decoded specification identity is
`0785b7ec49d724765771290f27700718d7159ce6cc68e87679118325cbda0089`.
These are distinct identities. The production bundled pin remains **0.0.7**;
0.0.8 was qualified only as an explicitly constructed scratch candidate.

Five source/test files admit the existing 0.0.7 and exact 0.0.8 candidates and
correct all three generation-bound launchers to propagate `SystemExit(main())`.
Reuse validates bounded exact launcher text before execution. Old launcher content
is non-reusable without mutating its generation. An explicit upgrade created a new
generation while preserving old generation content and receipt; no mode or timestamp
preservation claim is made.

Corrected check/reuse operations performed zero downloads. A corrupt replacement
attempt made 32 acquisition calls, refused the engine SHA/size mismatch before any
subprocess, and preserved the old active generation. Installed payload comparison
verified 1,130 files across 30 wheels with zero mismatches, excluding 30 RECORD files.
Original failed attempts remain retained, not overwritten by corrected evidence.

## Isolated functional proof and teardown

The corrected generation ends `F914C02E-1675-4D8E-ADCB-C57E1989537D`.
A PID-bound, read-only accessibility helper, with per-node PID guards and no
activation or launch, observed the same app identity (PID 74030, start
2026-11-05 22:31:15 Asia/Jakarta) initially showing two tasks and Connected, then
three tasks and Connected after an isolated fixture append. Both `firstAXProof`
and `refreshedAXProof` are true; all 21 post-append public reads passed.
This combines actual rendered refresh with exact candidate/public-read evidence.
An independent reviewer supported that bounded functional proof.

The controller's result remains **failed**, exit 1: its cleanup observer retained a
PS-live/kernel-gone race after TERM. It is not relabeled as a passing controller
run. Separate primary teardown verification established app and PGID absence,
then restored and verified the unique preference domain empty. A further inventory
confirmed all 56 identities retained by the controller sampler absent or reused,
including children with separate process groups. The sampler was lossy; this is
not an exhaustive descendant census. A separate kernel-executable census found zero live qualification app/helper or
scratch-generation executables. Independent review accepted the combined bounded
functional and final teardown evidence; it did not relabel the controller run.

An earlier UI-tool incident is retained: CUA stalled for 986 seconds and then
relaunched the unique app against normal HOME after the controlled deadline. It
read installed 0.0.7 metadata. Exact extra PID 90810 was stopped, its group was
verified absent and the unique preference domain restored. That attempt is not
positive qualification evidence, and zero reads of owner runtime metadata are not
claimed. Subsequent qualification used only the approved PID-bound helper.

## Current validation and limits

- Final reviewed repair Release build and strict bundle/startup diagnostic: explicit pass.
- Eight non-MainWindow packages: 1,527 tests passed on the final source; per-package manifest hashes
  and counts are in the checks record.
- Python tooling: 157 tests and 30 subtests passed.
- SwiftFormat 0.60.1: all 1,049 admitted files required no edits.
- SHA-verified CI-pinned SwiftLint 0.63.2: zero violations across 1,096 files.
- Repository guards: passed.
- MainWindow passed all 246 suites and 1,814 tests before the last narrow read-error
  repair. The final source then passed all 246 suites and 1,814 tests after an
  unlocked-console preflight on 2026-11-06. The earlier locked preflight is retained. No assertion was weakened, skipped or rebaselined.

These results do not establish whole-app pixel fidelity, continuous-unlocked
qualification, provider execution, performance budgets or owner acceptance.

## Final review repair and completed foreground gate

Final delivery review found that a regular executable launcher with no read
permission could throw before the non-reusable-generation catch, preventing an
explicit replacement. The read check now runs inside the existing qualification
catch, preserving cancellation behavior. Per-tool `0111` regressions verify no
acquisition/execution during checking, unchanged active pointer and old permissions,
and a fresh usable replacement on explicit preparation. MonitorCore passed all
440 tests after this correction. The engine inputs and generated launcher bytes
are unchanged, but the earlier live runtime/app experiment is not relabeled as an
execution of this final repair.

The guarded final-source MainWindow run completed successfully after the owner
unlocked the console. All required package, format/lint, guard, Release and bundle
checks passed; assertions were unchanged. The earlier runtime/app proof retains
its explicitly narrower source provenance and controller limitation.

## Remaining adoption and M04 boundary

The read-only remaining-consumer inventory found existing public successor/header
and workflow activity transports, but additive successor completeness outside loaded
windows and the current workflow unsettled/live-activity capability fence remain unresolved.
Older-engine settled activity reads must remain supported; the live capability
extends only unsettled reads.
Statistics cost/model presentation and stored changes depend on their later feature
plans; the inventory does not invent an owner-approved deferral or mark semantic
adoption complete. Missing capabilities never permit private persistence reads.

M04 visual direction is approved at HarflowDesign
`5b37a3d4d4d06b3d96c517cd384892e1ac6883cf`; see
[M04 preparation](M04-preparation.md) for exact paths/states. Native implementation,
production runtime adoption and aggregate migration acceptance remain separate.
Seven pre-existing tracker/M01 inputs were preserved and excluded from this stage.
