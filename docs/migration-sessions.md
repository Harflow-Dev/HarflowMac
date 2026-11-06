# HarflowMac migration sessions — native revision 3

Revised 2026-11-04. The [workspace session index](../../HARFLOW_MIGRATION_SESSIONS.md)
is authoritative for each brief, prerequisites, acceptance and receipt output.
Read [repository checklist](migration-plan.md) and applicable guidance before work.

## Current ownership

M01–M12, I01–I04 and O02/O03; co-own Rust responder/distribution/cutover rehearsal.

- **M01 — Native scope, design and acceptance inventory**; prerequisites and acceptance in the workspace index.
- **M02 — Xcode app host and SwiftPM modules**; prerequisites and acceptance in the workspace index.
- **M03 — Pinned Python runtime and public observation boundary**; prerequisites and acceptance in the workspace index.
- **M04 — Native shell and new-task composition**; prerequisites and acceptance in the workspace index.
- **M05 — Task transcript and bounded reading**; prerequisites and acceptance in the workspace index.
- **M06 — Queued messages and continuation**; prerequisites and acceptance in the workspace index.
- **M07 — Approvals, Needs you and checkpoints**; prerequisites and acceptance in the workspace index.
- **M08 — Native workflow editor and builder**; prerequisites and acceptance in the workspace index.
- **M09 — Workflow runs, parallel and recovery**; prerequisites and acceptance in the workspace index.
- **M10 — Native statistics and resources**; prerequisites and acceptance in the workspace index.
- **M11 — Onboarding, settings and native integration**; prerequisites and acceptance in the workspace index.
- **M12 — Redesigned Mac on Python acceptance**; prerequisites and acceptance in the workspace index.
- **I01 — Native Mac Rust adapter and responder**; prerequisites and acceptance in the workspace index.
- **I02 — Managed Rust acquisition and recovery**; prerequisites and acceptance in the workspace index.
- **I03 — Native distribution qualification**; prerequisites and acceptance in the workspace index.
- **I04 — Integrated native Rust acceptance**; prerequisites and acceptance in the workspace index.
- **O02 — Authorized owner cutover and canaries**; prerequisites and acceptance in the workspace index.
- **O03 — Observation and publication decision**; prerequisites and acceptance in the workspace index.

Each assignment is bounded and stops before the next. Record its lead receipt in
`docs/migration-receipts/<ID>.md`; co-owned work is included in that lead receipt.
No plan status authorizes live operations or publication. All new sessions are planned.

## Historical session evidence

S01–S09 keep their original IDs, outputs and recorded limits. S09 bounded evidence
is delivered, not accepted. Historical future S10–S50/X01–X03 are superseded and cannot be dispatched;
see the [crosswalk](../../HARFLOW_MIGRATION_PLAN_V3.md#supersession-and-scope-crosswalk).
The preserved briefs below describe original scope, not new authorization.

### S02 — Native pair qualification and references

- Status: complete with recorded qualification limits; see [S02 receipt](migration-receipts/S02.md). Lead: HarflowMac. Co-owned: HarflowMCP.
- Prerequisite receipts: S01.
- Checklist coverage: B0-MA-01 (final contribution), B0-MA-02 (final contribution), B0-MA-03 (final contribution), B0-MC-03 (final contribution).
- Scope and acceptance: Qualify the current selected Python/Mac pair, preserving dirty work; capture representative isolated states and document package versus source evidence and limitations.
- Output: lead receipt `docs/migration-receipts/S02.md`, with the evidence and identities required by the dispatch protocol.

### S03 — Freeze, parity and scope decisions

- Status: Decision record delivered; receipt acceptance and Proposed/Undecided scope outstanding. Lead: HarflowMCP. Co-owned: HarflowMac, HarflowDesign, HarflowEngine, HarflowWeb.
- Prerequisite receipts: S02.
- Checklist coverage: B0-MC-02 (final contribution), B0-MA-04 (final contribution), B0-DS-01 (final contribution), C0-DS-04 (partial), B0-EN-01 (final contribution), B0-WE-01 (partial).
- Scope and acceptance: Record Keep, Simplify, Deliberately remove and Undecided decisions in the v2 coverage ledger; obtain decisions on freeze, representative datasets and performance budgets, preserving unresolved scope and approved removals.
- Output: lead receipt `docs/migration-receipts/S03.md`, with the evidence and identities required by the dispatch protocol.

### S06 — Mac fixture compatibility

- Status: Evidence recorded; receipt acceptance pending. Lead: HarflowMac. Co-owned: HarflowMCP.
- Prerequisite receipts: S05.
- Checklist coverage: C0-MC-05 (final contribution), C0-MA-01 (final contribution), C0-MA-02 (final contribution).
- Scope and acceptance: Vendor the complete canonical bundle and prove matching digests, independent version gates, decoder compatibility and fallback.
- Output: lead receipt `docs/migration-receipts/S06.md`, with the evidence and identities required by the dispatch protocol.

## Conversational steering scope amendment — 2026-11-05

ST05 uses existing transcript/composer/status and ctl contracts for builder/orchestrator/worker steering; affected M07/M08/M09/M12 acceptance includes steering. Current Mac work continues unchanged; no ST05 implementation is assigned.
See the [current ST session briefs](../../HARFLOW_MIGRATION_SESSIONS.md#conversational-steering-track--accepted-scope-2026-11-05)
and [steering plan](../../HARFLOW_WORKFLOW_STEERING_PLAN.md). Scope acceptance does
not pass prior gates, permit live control or authorize releases.
