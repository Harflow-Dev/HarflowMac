# M08 — Private workflow file boundary

Implementation checkpoint, 2026-11-17, following the first-save name checkpoint
`85f16fd`. The controlled Save journey passed as recorded below; full M08/M12 remain separate gates.

The controlled app exposed an isolation failure: Foundation selected the real
Darwin temporary directory despite the supplied scratch `TMPDIR`, and atomic
draft writing required staging outside the permitted fixture. Direct scratch
writes succeeded. The unchanged restrictive profile correctly refused both.

Workflow input now honors the ctl client's explicit temporary root, rejecting a
malformed or unusable root without fallback or dispatch. Exclusive creation of a
private UUID directory grants cleanup ownership; its exclusive private input is
written and closed before ctl receives the path. Drafts use an exclusive private
sibling, write and close once, then rename within the destination directory.
Pre-publication failure preserves the previous draft and removes only the owned
temporary file. Atomic visibility is not a power-loss durability guarantee.

No wire operation, engine pin, provider execution, sandbox allowance, private
Darwin API, preference authority or canvas geometry changes.

## Observed verification

- The complete guarded MonitorCore aggregate passed 914 test definitions.
  An earlier narrowed discovery with aggregate execution was rejected by the
  runner; the final run used complete discovery and validated its event stream.
- Guarded workflow draft, save and conflict regressions passed 93 definitions
  across three suites, including private replacement and failure preservation.
- Formatting, strict uncached lint, legacy/private guards and diff checks passed.
- Independent plan and final implementation review were clear.
- After manual unlock, the final guarded native rerun passed all 24 cases
  across three definitions (readiness and name entry).

External evidence is under
`.claude-work/codex-2026-11-17/usable-mac-first-task/mac/`, notably
`private-input-r2`, `private-draft-r1`, and `private-files-hosted-r1`.
The controlled app built from clean `e286982` and completed Blank → name →
validation → Save → library → Edit/reopen using the qualified Python 0.0.14
runtime under the unchanged restrictive profile. The exact saved name was
`desktop-save-check-20261117`; the editor reopened Revision 1 with the graph
intact and the saved title static. Enter and Escape neither submitted nor reverted
the typed name. No workflow/provider run was started.

The app exited normally with code 0; the guard reported unchanged owner preference
fingerprints and no error. The bounded keep-awake assertion was stopped. Evidence:
`private-files-hosted-r2`, `runtime-fixtures/current-0014/gui-private-files-final`,
`private-files-verification.json`, and `workflow-saved-reopened.png`. This is a
controlled-bootstrap journey, not an installed ordinary-app or full native
acceptance claim. Nothing was installed, pushed or released.
