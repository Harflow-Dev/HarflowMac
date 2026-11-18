# M08 More actions and Delete confirmation

Date: 2026-11-17. Base: `a30519dec6bc84004ff9c709d2e832fc2d2dfba7`.
Status: implementation and data-only checks delivered; desktop acceptance deferred
at the owner's request. This does not accept full M08 or M12.

## Scope and design

Design authority: `b710856a31702e46e3b8f3a54be19f3cb7c422dc`,
`v2/scripts/states-workflow-gaps.js`, states `more-actions`,
`more-actions-unsaved`, `delete-confirm`, `delete-confirm-saved`, `delete-failed`.
The v2 coverage ledger deliberately removes Duplicate from the editor menu;
the internal copy operation remains available to Save copy and reload.

The More menu now separates Generate with agent from Delete…. Never-saved or
ineligible editors disable Delete. A saved workflow confirmation names its target,
keeps Cancel default, and includes “Unsaved changes will be lost.” only for actual
name/definition dirtiness. The failure state uses the existing HfUI Banner and the
approved fixed title with the observed failure reason.

## Fencing and acknowledgement

Confirmation captures editor, draft, load, generation, runtime and save-completion
evidence. Cancel, supersession, disappearance and context changes invalidate old
callbacks. The queued operation checks that evidence again immediately before
submitting the command; its own busy state does not invalidate that check.
Late success or failure cannot navigate or replace a later editor's errors.

Only an exact `deleted` name acknowledgement confirms success. Missing, malformed
or wrong-name acknowledgements preserve the editor/draft and explain that deletion
may already have occurred; they do not trigger an automatic retry. Public
`workflow-delete` remains name-only, without revision/identity compare-and-swap.
Client fencing does not establish atomic replacement-safe remote deletion. No
engine API or local draft-cleanup policy changed.

## Observed verification

- Guarded data-only run `mac-models-r3`: 35 definitions in five selected workflow
  VM suites passed, with no hosted setup. This includes Delete eligibility,
  asynchronous dialog delivery, clean/dirty Cancel, superseded/duplicate callbacks,
  pre-dispatch context changes, late results, runtime loss and acknowledgement
  uncertainty, plus affected Discard/undo/conflict regressions.
- Runner inventory/isolation tests: 595 passed.
- Full SwiftFormat lint, pinned SwiftLint 0.63.2, legacy/private-reference guards
  and diff checks passed after the final fixes.
- Primary self-review and independent final review cleared the implementation.
  Review found and corrected the queued-dispatch fence and runtime eligibility.
  Early fixture runs were corrected to await the deferred view-event publisher and
  provide the strict routing mock's void response; assertions were retained.

The registered `WorkflowDeleteHostedTests` source prepares clean/dirty Return and
Escape checks through the native presentation context, but was not executed.
Native menu contents, dialog keyboard/focus behavior and failure-banner visual
acceptance still require the owner's desktop cue. No GUI activation, keep-awake
assertion, real engine mutation, provider, installation, push or release occurred
in this slice. Node geometry was unchanged.

External check evidence is retained in the parent workspace under
`.claude-work/codex-2026-11-17/next-mac-rust/`.

## Escape repair (2026-11-18)

The first guarded hosted run of `WorkflowDeleteHostedTests` failed both Escape cases: the
confirmation sheet stayed attached and the delete request stayed set. The delete dialog makes its
Cancel action the default, and SwiftUI binds Return to it, which left no button holding Escape
(the native sheet's Cancel carried Return; Delete carried no key).

The window presentation context now answers Escape for an alert or dialog whose default action is
a cancel: a local key monitor clicks the sheet's own default button once per presentation, through
the native button path rather than the action closure. It acts only on the sheet that began on the
host window after the presentation started, never on a sheet already attached, a nested sheet or
another window; the residual case of a foreign sheet with an identically titled default is
documented in `macos/HfFoundation/HfUI/AGENTS.md`. Discard and the Parallel message dialog use the
same pattern and are covered by the same change.

Observed through the guarded runner: `WorkflowDeleteHostedTests` and `WorkflowDiscardHostedTests`
(Return and Escape, now with an explicit sheet-dismissed assertion) passed, as did the new
`PresentationEscapeHostedTests` (alert and dialog, repeated Escape, Return, a non-cancel default
keeping native Escape, a nested sheet, a pre-attached foreign sheet, two windows) and the HfUI
package with the eligibility, decision and monitor-lifecycle tests. Desktop acceptance of dialog
keyboard and focus behaviour still requires the owner's cue.
