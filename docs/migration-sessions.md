# HarflowMac migration sessions

Status: planned. The [workspace session index](../../HARFLOW_MIGRATION_SESSIONS.md) defines dispatch order; the [repository checklist](migration-plan.md) retains full item criteria. These session specifications include work led or co-owned by this repository.

## Dispatch protocol

Read the workspace `AGENTS.md` and `HARFLOW_MIGRATION_CHECKLIST.md`, the lead and co-owned repositories' `AGENTS.md` files where present, their `docs/migration-plan.md` files, applicable package guidance, and the session and all accepted prerequisite receipts before work. The workspace session index gives the full sequence. A session is a bounded assignment, not an instruction to start the next session. A standalone session lead owns the normal required plan/code reviews, test delegation and validation; a worker explicitly handed off by an orchestrator follows that handoff and does not restart its workflow. Stop and report a concrete unresolved ambiguity or missing prerequisite instead of inventing a decision.

Use primary checkouts and preserve concurrent work. Never share a writable state root between engines or import historical task/run/event state. Work on isolated roots and fixtures unless separately authorized. MCP owns canonical contracts until explicit S50 transfer. Cross-repository package changes require a committed producer, exact consumer pin and clean install without sibling source dependencies; a necessary push requires current authorization. Do not run concurrent sessions that mutate the same repository, generated contract bundle or IPC boundary. Within a session, coordinate delegated workers through explicit file ownership. Approval for publication, signing, paid probes, live state, registrations, cutover and retirement is separate and current; prepare concrete evidence first.

A session receipt is proposed at the lead repository's `docs/migration-receipts/<session>.md`. It records prerequisites, accepted scope and decisions, exact commits for every involved repository, contract/design/package/runtime identities, actual commands and results, platform and profiles, acceptance evidence, deviations, missing checks and authorization or blockers. Distinguish local, committed, pushed, CI-passed, packaged and released states. It contains technical evidence, not review transcripts. A multi-repository session has one lead receipt covering each repository. A receipt is accepted only after the applicable review and owner decisions. All sessions here are planned, not accepted.

Checklist items may span sessions. Each mention is partial until the final contributing session identified below; even then, check the source item only after all contributing receipts and the full original item acceptance have been reviewed and accepted. The sequential order is the safe default; S25's isolated research exception and optional sessions are explicit. There is no duration guarantee. Defects or follow-up work discovered during a session need separately scoped assignments; they do not automatically expand or advance the session.

Copyable dispatch (replace bracketed inputs):

```text
Run session Sxx from HARFLOW_MIGRATION_SESSIONS.md and the lead repository's docs/migration-sessions.md.
Accepted prerequisite receipt paths and IDs: [paths and IDs]
Pinned contract, design, package and runtime identities: [commits, digests and paths]
Allowed isolated roots, fixtures and external actions: [scope and authorizations]
Return the session receipt at the specified lead-repository path, including all repository commits, evidence, decisions and blockers. Complete only this session; do not start the next.
```

For optional work replace `Sxx` with `X01`, `X02` or `X03`.

The [v2 coverage ledger](../../HarflowDesign/v2/docs/migration-coverage.md) is an optional workspace coordination reference, not a build dependency. S10-Gxx bounded gap sub-sessions follow scope approval and obtain exact design approval before dependent work; unresolved required states block only their dependent feature. Independent work continues. The approved mock does not establish runtime capability or authority. Existing S01 evidence and S02 status remain as recorded in their receipts.

## Sessions

### S02 — Native pair qualification and references

- Status: complete with recorded qualification limits; see [S02 receipt](migration-receipts/S02.md). Lead: HarflowMac. Co-owned: HarflowMCP.
- Prerequisite receipts: S01.
- Checklist coverage: B0-MA-01 (final contribution), B0-MA-02 (final contribution), B0-MA-03 (final contribution), B0-MC-03 (final contribution).
- Scope and acceptance: Qualify the current selected Python/Mac pair, preserving dirty work; capture representative isolated states and document package versus source evidence and limitations.
- Output: lead receipt `docs/migration-receipts/S02.md`, with the evidence and identities required by the dispatch protocol.

### S03 — Freeze, parity and scope decisions

- Status: planned. Lead: HarflowMCP. Co-owned: HarflowMac, HarflowDesign, HarflowEngine, HarflowWeb.
- Prerequisite receipts: S02.
- Checklist coverage: B0-MC-02 (final contribution), B0-MA-04 (final contribution), B0-DS-01 (final contribution), C0-DS-04 (partial), B0-EN-01 (final contribution), B0-WE-01 (partial).
- Scope and acceptance: Record Keep, Simplify, Deliberately remove and Undecided decisions in the v2 coverage ledger; obtain decisions on freeze, representative datasets and performance budgets, preserving unresolved scope and approved removals.
- Output: lead receipt `docs/migration-receipts/S03.md`, with the evidence and identities required by the dispatch protocol.

### S06 — Mac fixture compatibility

- Status: planned. Lead: HarflowMac. Co-owned: HarflowMCP.
- Prerequisite receipts: S05.
- Checklist coverage: C0-MC-05 (final contribution), C0-MA-01 (final contribution), C0-MA-02 (final contribution).
- Scope and acceptance: Vendor the complete canonical bundle and prove matching digests, independent version gates, decoder compatibility and fallback.
- Output: lead receipt `docs/migration-receipts/S06.md`, with the evidence and identities required by the dispatch protocol.

### S10 — Approved v2 design and gap reconciliation

- Status: planned. Lead: HarflowDesign. Co-owned: HarflowMac.
- Prerequisite receipts: S09.
- Checklist coverage: C0-DS-01 (final contribution), C0-DS-02 (final contribution), C0-DS-03 (final contribution), C0-DS-04 (final contribution), E0-DS-01 (final contribution).
- Scope and acceptance: Reconcile the pinned approved v2 baseline, intent ledger and contract/design gaps. For each retained or approved simplified feature, commission missing states in v2 and obtain explicit owner approval with exact commit/path/state before dependent implementation. Use bounded S10-Gxx sub-sessions as needed; independent work continues.
- Output: lead receipt `docs/migration-receipts/S10.md`, with the evidence and identities required by the dispatch protocol.

### S24 — Electron on Python acceptance

- Status: planned. Lead: HarflowDesktop. Co-owned: HarflowMCP, HarflowMac, HarflowDesign, HarflowClient.
- Prerequisite receipts: S23.
- Checklist coverage: E0-MC-01 (final contribution), E0-MA-01 (final contribution), E0-DS-02 (final contribution), E0-CL-05 (final contribution), E0-CL-06 (final contribution), E0-CL-07 (final contribution), E0-CL-14 (final contribution), E0-DE-02 (final contribution), E0-DE-06 (final contribution), E0-DE-12 (final contribution).
- Scope and acceptance: Accept Electron on Python against approved v2 production pixels and the retained/simplified feature ledger, including reconnect, disposal, accessibility, performance, clean pinned install and sandbox smoke. Do not restore removed UI for parity; record exact identities and limitations.
- Output: lead receipt `docs/migration-receipts/S24.md`, with the evidence and identities required by the dispatch protocol.

### S46 — Cutover rehearsal

- Status: planned. Lead: HarflowEngine. Co-owned: HarflowMac, HarflowDesktop, HarflowMCP.
- Prerequisite receipts: S45.
- Checklist coverage: I0-EN-03 (final contribution), O0-EN-02 (partial), O0-MA-01 (final contribution), O0-MA-02 (partial), O0-MC-01 (partial).
- Scope and acceptance: Rehearse isolated archive, restore, validated definition/configuration/preference imports, registration backup and handoff; document rollback boundaries, exclusive roots and no history import.
- Output: lead receipt `docs/migration-receipts/S46.md`, with the evidence and identities required by the dispatch protocol.

### S47 — Owner cutover and canaries

- Status: planned. Lead: HarflowDesktop. Co-owned: HarflowEngine, HarflowMac, HarflowMCP.
- Prerequisite receipts: S46.
- Checklist coverage: O0-EN-02 (final contribution), O0-MA-02 (partial), O0-MC-01 (partial).
- Scope and acceptance: Only with explicit owner authorization, settle active work, perform cutover and canaries; retain any qualified early-use next store and record first writes and external effects.
- Output: lead receipt `docs/migration-receipts/S47.md`, with the evidence and identities required by the dispatch protocol.

### S48 — Observation and go/no-go

- Status: planned. Lead: HarflowDesktop. Co-owned: HarflowEngine, HarflowMac.
- Prerequisite receipts: S47.
- Checklist coverage: O0-DE-01 (partial), O0-MA-02 (partial).
- Scope and acceptance: Complete owner-agreed observation period and restart/upgrade checks; record elapsed time and evidence for release decision.
- Output: lead receipt `docs/migration-receipts/S48.md`, with the evidence and identities required by the dispatch protocol.

### S50 — Contract transfer and retirement

- Status: planned. Lead: HarflowMCP. Co-owned: HarflowEngine, HarflowMac, HarflowDesktop, HarflowClient.
- Prerequisite receipts: S49.
- Checklist coverage: O0-MC-01 (final contribution), O0-EN-03 (final contribution), O0-MA-02 (final contribution).
- Scope and acceptance: With explicit owner decisions, transfer canonical contracts once with consumer/provenance updates and retire legacy product; cleanup needs separate authorization and never deletes user repositories implicitly.
- Output: lead receipt `docs/migration-receipts/S50.md`, with the evidence and identities required by the dispatch protocol.
