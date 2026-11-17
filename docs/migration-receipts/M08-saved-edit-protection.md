# M08 saved workflow edit protection

Date: 2026-11-17. Source checkpoint: `88e4cd8d94a8ab86bcc358e350e77d413ce59c3e`.
This is scoped evidence, not full M08, M12 or migration acceptance.

## Behavior

Saved Discard uses the approved Design commit
`b710856a31702e46e3b8f3a54be19f3cb7c422dc`,
`v2/scripts/states-workflow-gaps.js`, `workflow-editor/discard-confirm`.
It reads the current saved revision before presenting the dialog. Cancel is
default; confirmation rechecks the editor context and saved identity, revision
and definition. A newer save completion is checked before draft persistence can
adopt it or delete its draft. Old callbacks remain inert after navigation or
replacement. Never-saved drafts retain their existing reset behavior.

Python 0.0.14 returns a flat definition from `workflow-get`. The adapter validates
that structure before accepting it; malformed explicit envelopes do not fall
through to flat parsing. The first controlled run exposed the earlier nested-only
guard, which refused safely and preserved the draft. The checkpoint above fixes
that mismatch and includes flat success, malformed-shape and changed-record tests.

## Verification

- Final guarded regression: 113 definitions in six workflow, draft, undo,
  conflict and Discard suites passed (`discard-flat-models-r1`).
- Final registered native confirmation test passed (`discard-flat-hosted-r1`),
  including Return choosing Cancel.
- Runner inventory/isolation checks: 586 passed. Full format lint, pinned
  SwiftLint 0.63.2, legacy/private-reference guards and diff checks passed.
- Independent final source review cleared round three. Earlier test fixtures
  were corrected to use one mutable Mockable response provider; preservation
  assertions were retained.

## Controlled desktop evidence

The external controlled host ran on macOS 26.6.2, arm64, using the qualified
Python 0.0.14 fixture and unchanged restrictive profile
`a1dc63f3560f46ade4ab4b90d62088f7a5ee66481b4b64d8d804ab3681cf34a8`.
It was not the ordinary installed app. Binary SHA-256:
`e09e0ec21ef9faa0b98a81c016e5ac961b0939d88c191c92d1cfc7f8546d7ab1`.

The owned workflow was `desktop-save-check-20261117`. Plan edits saved as
Revision 2 and reopened exactly; unsaved instructions survived library navigation
and reopening. On the corrected build, Return cancelled Discard and retained the
draft. A competing public CAS save advanced the saved workflow to Revision 3;
stale Save refused and retained the draft. Another public CAS save advanced it to
Revision 4 while the revision-3 confirmation was open; confirmation refused and
retained the draft. A fresh revision-4 confirmation restored the saved definition.
Finally, a new Plan edit saved as Revision 5 and reopened with the exact text:
`Final saved-edit checkpoint: exact Plan text after confirmed discard.`

The final app exited normally with exit 0, no launcher error, and unchanged owner
preferences. The owned GUI and bounded keep-awake assertion stopped. No provider,
installation, push or release occurred; existing node dimensions were unchanged.

External evidence is retained in the parent workspace under
`.claude-work/codex-2026-11-17/usable-mac-first-task/mac/`: guarded runner manifests,
`runtime-fixtures/current-0014/gui-saved-discard-flat-r1/receipt.json`, the two
`saved-edit-cas-*` public operation receipts, and the `saved-edit-*.png` captures.
