# M08 — First-save workflow name

Implementation checkpoint, 2026-11-17. This closes the missing first-save name
control found during the M08-A2 manual journey. It is not full M08/M12 acceptance.

The owner approved HarflowDesign `533c5798873139a17d5519288e2df57b2de38ab7`,
`v2/scripts/states-workflow-naming.js`, all eight `name-entry-*` states; approval
is recorded at `7de89a4`. A native single-line field occupies the title slot only
for never-saved workflows. It binds directly to the existing draft name and
validation flow. Saved titles remain static. Canvas node dimensions are unchanged.

An unchanged native end-editing write no longer invalidates successful validation
or reschedules draft/history work. Genuine edits retain the original fences.
The field adds no save/submit/cancel keyboard callbacks or engine operation.

## Observed checks

- Guarded workflow regression passed 586 definitions in 94 selected suites,
  including the unchanged-name regression. Existing AppKit fixtures are included;
  this is not a complete MainWindowFeature package gate.
- The registered guarded hosted suite passed all three definitions: 16 readiness
  cases and eight name-entry cases across both appearances and normal/minimum
  surfaces. It exercised the production binding, draft persistence, blur retention,
  immediate whitespace refusal, long names and static saved-title transition.
- The initial hosted run exposed duplicate blur writes and an eagerly evaluated
  test projection. Both were corrected; the final post-fix run passed.
- Formatting, strict uncached lint, legacy/private guards and diff checks passed.
  Independent plan review and final review round two were clear.

Evidence is retained outside the repository under
`.claude-work/codex-2026-11-17/usable-mac-first-task/mac/` (`name-models-r1`,
`name-hosted-r2`). Hosted name tests compose the production title, Save and status
components; full-header fitting and actual keyboard behavior are separate manual
checks. Current-source controlled Python-backed Save → library → reopen remains
pending at this checkpoint. No provider, installation, push or release is included.
