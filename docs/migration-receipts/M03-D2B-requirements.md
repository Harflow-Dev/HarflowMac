# M03-D2B — blocked production cutover requirements

> Historical planning record: the design-decision gate below was superseded by owner approval of HarflowDesign `227da87ade53fd30af7a3e28776258c1bd72c72c` and the subsequent explicit D2B implementation assignment. The original requirements remain evidence; this record does not describe the current implementation status.

Status: proposed bounded follow-up, not design approval or completed migration. Recorded2026-11-05. D2A provides an independent internal public observation layer; it is deliberately absent from production composition. Both existing private production readers remain active.

## Required design decision

Observed design reference: HarflowDesign `9cfe4ce81789ed87c7ee40c10802ff0e3b2c7552`, `v2/docs/migration-coverage.md`, G-HISTORY. Loss, reconnect and unavailable states remain open. The preserved M01-design receipt requires explicit owner approval and immutable commit/path/state references before native adaptations. Existing controls or placeholders elsewhere do not approve these new meanings.

Commission only the following state decisions through the tracker; this document does not authorize sibling edits or new UI implementation:

1. **Qualified totals:** loading, observed totals, unavailable/partial capture, unsupported normalization and capacity-limited totals. Unknown must not display as zero. Specify whether partial observed values may be shown and how their coverage is communicated. Preserve independently authoritative snapshot usage/answer and child count.
2. **Assignment prompt:** complete verified text versus preview-only, unverified/truncated available text, integrity failure, unavailable/refused and loading. Specify provenance and copy/full-text behavior. Historical display prompts and normalized event text are not the stored assignment. No unconditional String?/event fallback may erase those distinctions.
3. **Activity history:** bounded oldest/newest paging, loss/skips/gaps, unsupported records, reset/reconnect, missing capability, nonprogress, capacity blockage and explicitly observed terminal drain. Final lifecycle never establishes complete capture. Define the existing no-tools claim's admissible coverage; absence from a visible window is insufficient.
4. **Reading position and identities:** source/session epoch plus file-order occurrence identity, including valid duplicate/regressing sequence numbers. Define anchor preservation while prepending, resetting and reaching capacity; no silent eviction, global sequence sorting/deduplication or implied arbitrary-depth unlimited history.
5. **Raw events provenance:** bounded public normalized records, including unsupported payloads/stubs, with a truthful source label. Separate recovered transcript data and authority. Public normalized JSON is not the original private JSONL bytes.

Return immutable approved loading/empty/populated/error/interaction state references, light/dark and native keyboard/focus/accessibility/Reduce Motion/narrow behavior as applicable. This is a bounded missing-state requirement, not restoration of deliberately removed task tabs, Inspector, search/filter controls or other old UI.

## Exact consumer dependencies

- `InspectorView` renders numeric activity counts; `TaskDetailVM+Inspector` currently qualifies only a note. Optional totals need an approved consumer model/rendering boundary.
- `TaskDetailVM+Timeline` prefers display_prompt then String? fallback; Parallel and Prompt consumers also erase provenance. Adopt typed taskPrompt states before assignment claims.
- `TaskDetailTimelinePresentation.noToolCallsRecorded` uses legacy availability/paging only, and loadingHistory reconstruction loses richer coverage. Both detail and parallel need qualified observed-traversal input.
- `TaskEvent.id` and `TimelineItem.id` are sequence-based; ParallelActivityHistory restores using sequence minima/comparisons. These cannot represent every valid public file order.
- `TaskDetailViewRepository.eventsPath` supplies a private-path overlay that matches the still-active private reader. Replace the actual raw record source and label together at cutover, not by relabelling old bytes.

## Cutover and validation

After approval, adapt these consumers and replace BOTH EventStreamRepositoryImpl activity EventFileTailer/EventPages/LineTail and its independent cumulative-summary LineTail scans together. Bind shared public lifetime/leases, explicit runtime invalidation callback, fresh ctl/event capability gates, cancellation and queued publication fences. Keep recoveryActivity separately labelled. Remove obsolete private path/read helpers only after production callsite audit; preserve app-owned preferences/runtime files and public CLI inputs. Later note: `EventFileTailer`, `EventPages`, `LineTail` and `TaskTitle` were removed at the commit "Remove unused engine-file readers from MonitorCore" (2026-11-13); the engine is read only through `task-events`.

Use immutable0.0.8 event/prompt contracts unless an accepted delta is separately assigned. Runtime0.0.7 must explicitly refuse missing capabilities; no private/MCP fallback or automatic repin/acquisition. Public watcher adoption remains separate.

Acceptance requires meaningful off-main/boundedness/cursor/lease/ABA/anchor tests, isolated rendered evidence for changed consumer behavior, the full serialized guarded native loop and Release/strict-bundle checks. The historical M03-C viewport-test deferral is specific; it does not waive new failures or changed coupling. No private-removal, D2, M03 or runtime-performance acceptance is implied by D2A unit validation.
