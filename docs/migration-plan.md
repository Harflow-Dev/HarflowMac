# Native product continuity migration checklist

Status: planned, 2026-11-02. All work items remain unverified.

Own current daily-use native app maintenance and its contract consumption.
Preserve existing dirty source work. No new product features are implied by this
migration. Inputs are the reproducible current app and Python contract; outputs
are baseline captures, compatibility evidence and retirement handoff.

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
publication). It is not a build dependency. Freeze and qualify the reproducible
existing baseline without waiting for open feature tickets. Review v1 scope in a
parity ledger, including proposed sidebar additions, instead of assuming tickets
or UI polish are migration requirements without an accepted ledger decision. All boxes below are deliberately unchecked;
scaffolds alone do not establish completion. Early-use gates and defaults remain
subject to evidence and explicit authorization for root registration. Use fresh
Rust state; archive historical task, run and event records rather than importing
them. Import only definitions, configuration and preferences, with an explicit
registration backup and handoff. No engine may share a writable root.

Stage dependencies: B0 → C0 → E0 → R0 → I0 → O0; native maintenance
continues as needed throughout, within the freeze policy.

## B0 — daily-use baseline

- [ ] B0-MA-01 Record current commit, dirty work and qualified build behavior;
      preserve uncommitted changes and report any unverified native behavior.
- [ ] B0-MA-02 Capture representative task, workflow, approval, settings and
      accessibility states for the parity ledger using isolated fixtures.
- [ ] B0-MA-03 Map public contract use and direct file-read coupling, including
      event observation, and record relevant preferences for later import.
- [ ] B0-MA-04 Apply the current freeze policy to maintenance and capture any
      accepted defect or behavior change in the parity ledger.

## C0 / E0 — compatibility and reference

- [ ] C0-MA-01 When Python contracts change, re-vendor the full canonical
      fixture bundle and compare manifest digests byte-for-byte.
- [ ] C0-MA-02 Verify decoders, independent version gates and fallback behavior;
      make only necessary compatibility changes.
- [ ] E0-MA-01 Supply verified behavioral and pixel reference evidence to the
      client parity review; distinguish observations from design approvals.

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
