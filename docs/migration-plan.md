# Native product continuity migration checklist

Dispatchable work packages: [migration sessions](migration-sessions.md).

Status: planned, 2026-11-02. All work items remain unverified.

Own current daily-use native app maintenance and its contract consumption.
Preserve existing dirty source work. No new product features are implied by this
migration. Inputs are the reproducible current app and Python contract; outputs
are baseline captures, compatibility evidence and retirement handoff.

## Redesign target and intent

The approved baseline is [HarflowDesign v2 at commit `3643d083700be4032c93237813b573d04bab6ab1`](https://github.com/Harflow-Dev/HarflowDesign/tree/3643d083700be4032c93237813b573d04bab6ab1/v2), including the owner-approved Mac connector amendment. Consult the optional workspace [coverage and intent ledger](../../HarflowDesign/v2/docs/migration-coverage.md); it is not a build dependency. Use the native app as behavioral and source inventory, not as the redesigned pixel template. Missing required states need a v2 design and explicit owner approval with exact commit, path and state before dependent implementation. Approval of visuals does not authorize new authority, public contract changes, backends or deferred features. Core execution safety and observability remain required.

## Dispatch and boundaries

Work only on the assigned item. Read the workspace AGENTS.md, this repository's AGENTS.md if present, and
applicable package instructions first; preserve concurrent edits and use primary checkouts.
The orchestrator delegates unit tests under the current workflow. A checkbox is
not authorization to start runtimes, mutate real roots, register clients, push,
release, clean up, or expand scope. Use disposable roots and workspaces where
needed. Report a blocker with concrete evidence; task status is not proof of
completion. Repository builds and tests must not depend on sibling checkouts.

The optional [workspace coordination index](../../HARFLOW_MIGRATION_CHECKLIST.md)
uses B0 (baseline), C0 (contracts and design), E0 (client and Electron on
Python), R0 (Rust parity), I0 (integrated stack), and O0 (owner cutover and
publication). It is not a build dependency. Freeze and qualify the reproducible existing baseline without waiting for open
feature tickets. Use the v2 intent ledger to decide retained and simplified scope;
legacy UI parity and open tickets do not independently mandate inclusion. All boxes below are deliberately unchecked;
scaffolds alone do not establish completion. Early-use gates and defaults remain
subject to evidence and explicit authorization for root registration. Use fresh
Rust state; archive historical task, run and event records rather than importing
them. Import only definitions, configuration and preferences, with an explicit
registration backup and handoff. No engine may share a writable root.

Stage dependencies: B0 → C0 → E0 → R0 → I0 → O0; native maintenance
continues as needed throughout, within the freeze policy.

## B0 — daily-use baseline

- [x] B0-MA-01 Record current commit, dirty work and qualified build behavior;
      preserve uncommitted changes and report any unverified native behavior.
- [x] B0-MA-02 Capture representative task, workflow, approval, settings and
      accessibility states for the parity ledger using isolated fixtures.
- [x] B0-MA-03 Map public contract use and direct file-read coupling, including
      event observation, and record relevant preferences for later import.
- [ ] B0-MA-04 Apply the current freeze policy to maintenance and capture any
      accepted defect or behavior change in the parity ledger.

S02 evidence: [qualified baseline receipt](migration-receipts/S02.md), including
recorded limitations. B0-MA-04 remains for S03.

## C0 / E0 — compatibility and reference

- [ ] C0-MA-01 When Python contracts change, re-vendor the full canonical
      fixture bundle and compare manifest digests byte-for-byte.
- [ ] C0-MA-02 Verify decoders, independent version gates and fallback behavior;
      make only necessary compatibility changes.
- [ ] E0-MA-01 Supply verified behavioral and source inventory evidence to the
      v2 scope review; native pixels are not the redesign template.

## O0 — owner handoff

- [ ] O0-MA-01 Rehearse preference export or transfer on isolated copies and
      verify each imported preference; do not import historical execution state.
- [ ] O0-MA-02 Record unresolved discrepancies, archive and rollback evidence;
      retire the native product only on explicit owner decision.

## Validation

Run relevant guarded Swift package suites sequentially through
`scripts/test-swift-package.py`, plus `python3 scripts/check-legacy-names.py`
and `scripts/check-private-refs.sh`; see [development](development.md) and
[architecture](architecture.md). For changes under `macos/`, follow its
AGENTS.md and package instructions, including format and lint. Never launch a
development build against real user state.

## Handoff evidence

For every assigned item report: item ID and result; repository and dependency
commit IDs; fixture manifest hash where applicable; commands, environment,
results and evidence locations; local, committed, pushed, CI-passed, packaged
and released state, stated separately; approved design commit, path and state where
applicable; deviations, blockers and remaining work. Record unrun checks and
why. Do not infer passing gates from a dispatched task's status.
