# Native Mac redesign and engine migration checklist

Revised 2026-11-04. Governing [revision 3](../../HARFLOW_MIGRATION_PLAN_V3.md),
[workspace gates](../../HARFLOW_MIGRATION_CHECKLIST.md) and [current sessions](migration-sessions.md).

HarflowMac remains the product. Reuse sound SwiftUI/AppKit/domain/repository code;
apply approved v2 with native adaptations, then switch its public adapter to Rust.
The requested Xcode app host + SwiftPM modules was delivered in M02 and restructured in M02-B (one project, grouped local packages, per-package schemes).

- [x] B0-MA-01/02/03 S02 bounded baseline, captures and coupling inventory delivered.
- [ ] C0-MA-01/02 Accept S06 exact fixture/decoder/fallback evidence; three MainWindow
  failures retain their bounded owner waiver, not a passing baseline.
- [ ] M01 Scope/code-to-design inventory, missing-state M01-Gxx receipts and native
  performance/accessibility budgets; resolve relevant Proposed/Undecided rows.
- [ ] M02 Thin .xcodeproj app target and SwiftPM modules: decide shell/test ownership,
  preserve identity/resources/Bundle.module/CI/packaged-startup/release pipeline; M02-B restructure recorded.
- [ ] M03 Pin/qualify intended Python 0.0.8; migrate direct event/state reads/watches
  to bounded public operations. Eliminate private persistence coupling before Rust.
- [ ] M04–M07 Native shell/composer, task transcript/right-pane/capture/history,
  queued messages/continuation, inline exact-action approvals and Needs you.
- [ ] M08–M10 Workflow editor/builder/run/nested/parallel/recovery, statistics/cost/
  incomplete accounting and resources with scope-approved observations.
- [ ] M11 Settings/onboarding/harnesses/human-only allowlist, menu bar/notifications,
  deep links/single instance, lifecycle/preferences and truthful unavailable states.
- [ ] M12 Complete redesigned native acceptance on exact Python route, approved
  pixels/states, native budgets, accessibility and isolated packaged evidence.
- [ ] I01–I04 Native Rust adapter/responder secure storage, managed engine
  distribution/update/recovery/signing and same product acceptance on fresh roots.
- [ ] O01–O04 Rehearse/authorize cutover, observe and publish; retain Mac, archive
  old histories, validate definitions/config/preferences and registration handoff.

Mac freeze now permits separately assigned redesign/build-transition work while
other feature expansion remains scoped. No native failure is automatically waived
for new UI. Keep guarded package tests serialized and use actual rendered-flow checks;
follow existing development/release guidance. No real user state in development.

## Product engine API

The native app uses **harflow-ctl as its engine API**. MCP is agent-facing only:
no native MCP client or fallback. Existing harflow-setup acquisition/registration
tasks remain separate from product operations. If required app functionality lacks
a ctl operation, first scope additive work in the current canonical contract owner:
HarflowMCP before accepted O04 transfer, HarflowEngine afterward. Specify provenance,
authority, bounds and unknown/refusal semantics, capability, fixtures and tests;
then coordinate byte-identical fixture vendoring and consumer adapters. Pre-transfer
native work starts in Python; Rust implements that same accepted ctl contract.
After transfer, later Web work does not depend on retired Python. Missing API is not
permission to read persistence, invoke agent MCP or invent semantics. M03 may split
bounded suffix sessions.

## Parallel-track coordination

M01 shared readiness follows S09 coverage disposition and the native capability,
code/private-read inventory, with ratified initial ctl/capability/fixture baseline,
exact identities, explicit blocking gaps and canonical change owner. M02+ native
and R01/R02+ Rust work may then run concurrently with disjoint files/isolated roots.
Pin each accepted subset, serialize canonical changes under MCP before O04 (Engine
afterward), coordinate consumer fixture deltas and carry forward affected conformance.
Both accepted M12 and R14 are required before I01; missing baseline/fault evidence
is not automatically waived. Read-only research remains separately assignable.

## Boundaries and evidence

This plan authorizes no implementation by itself. Follow workspace/child/package
AGENTS.md and the current session brief; preserve concurrent work in primary
checkouts. Use isolated roots/fixtures. No implicit live-state, install, registration,
paid-probe, signing, push, publication, retirement or deletion authority. Record exact
commit/contract/design/runtime/profile identities, actual checks/reviews, missing
coverage and owner decisions in the lead receipt. Delivery and acceptance differ.
Builds/tests must not depend on sibling source checkouts. Documentation-only plan
changes need link/consistency checks, not product test reruns.

## Conversational steering scope amendment — 2026-11-05

ST05 uses existing transcript/composer/status and ctl contracts for builder/orchestrator/worker steering; affected M07/M08/M09/M12 acceptance includes steering. Current Mac work continues unchanged; no ST05 implementation is assigned.
See the [current ST session briefs](../../HARFLOW_MIGRATION_SESSIONS.md#conversational-steering-track--accepted-scope-2026-11-05)
and [steering plan](../../HARFLOW_WORKFLOW_STEERING_PLAN.md). Scope acceptance does
not pass prior gates, permit live control or authorize releases.
