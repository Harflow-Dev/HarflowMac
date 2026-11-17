# M08 — Private workflow file boundary

Implementation checkpoint, 2026-11-17, following the first-save name checkpoint
`85f16fd`. Full M08/M12 and the controlled Save journey remain separate gates.

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
- The final native rerun could not activate while the desktop was locked;
  it remains pending, not a native success claim.

External evidence is under
`.claude-work/codex-2026-11-17/usable-mac-first-task/mac/`, notably
`private-input-r2`, `private-draft-r1`, and `private-files-hosted-r1`.
Current-source build and unchanged-profile Python-backed Save → library → reopen
are pending at this checkpoint. Nothing was installed, pushed or released.
