# Proposed public task-list watcher — Rust migration follow-up

Recorded2026-11-04 under M03, at the owner's request. **Planning only; no API name/schema, implementation or acceptance is ratified.** Public polling is the selected Python-route strategy now. This document is a tracker handoff, not an edit to canonical contracts or Engine migration plans.

## Purpose and replacement boundary

Provide a bounded public ctl invalidation wait so a client can replace frequent polling without observing private persistence. The task-list observation source requests refreshes; existing public task-history/status reads remain authoritative. Keep one small source interface/lifetime in Mac composition so a future ctl watcher can replace the polling driver without rewriting paging, titles, selection, notifications or action barriers. It returns invalidation signals, not task facts or storage paths.

Do not expand this first proposal into transcript streaming, general subscriptions, a daemon/socket service or an app MCP client. Existing interaction-events is a replay feed of notification episodes, not a complete task-list watermark. Workflow notification subscriptions and one-run workflow-wait likewise do not cover starts/header/catalog changes.

## Candidate contract to scope later

A possible additive capability/operation is task-list-watch.v1 / `harflow-ctl task-list-watch`; naming and exact schema remain proposals. Prefer one bounded invocation returning one JSON document, with an opaque selected-root/producer-generation cursor and a wait ceiling (candidate0–30seconds). Separate baseline, changed, timeout, continuity-reset and unavailable outcomes; timeout/equal token must never certify unchanged execution/liveness. Preserve deadline-driven lifecycle reconciliation because an owner can die without writing metadata.

Authority must precede source/cursor inspection: verified direct caller, exact selected root/runtime; managed or undecidable callers refuse without revealing another scope. No root initialization, task execution/recovery, retention cleanup or registration may be disguised as watching. Specify cursor length/response/wait/resource bounds, typed malformed/expired/wrong-scope refusals, transport cancellation and no overlapping waits. Unknown observation continuity means reset/unavailable plus public resnapshot, never a trustworthy unchanged response.

## Lost-wake requirement

Establish the observation boundary **before** reading the initial public snapshot. Retain that pre-read cursor through refresh and submit the following wait from it. On change/reset, retain the next acknowledged cursor before refreshing again. Acquiring a new cursor only after a list creates an unobserved gap and is unacceptable.

Across separate ctl processes, the producer must prove conservative continuity: relevant publication after a valid boundary cannot be reported as trustworthy unchanged. Root replacement, producer restart, overflow, eviction, response loss or observer interruption must resynchronize. A directory mtime, internal catalog scan generation or process-local counter alone is insufficient. Producer-owned monotonic/epoch machinery or an equivalently proven conservative mechanism belongs behind the public interface; the client must not interpret it.

Coarse invalidations should cover changes affecting public TaskList/current snapshots: creation/update/removal/retention, status/title/attention/queue/control availability, public reservation projections and catalog preparation/blocker/authority transitions. No invalidation proves successful execution, cancellation, ownership, output drain, approval delivery or complete history; subsequent public reads establish facts.

## Conformance and resource lifecycle

Required cases: baseline/change/timeout/reset/unavailable; missing capability; caller/root/cursor refusals; mutations before/during/after snapshot; burst/coalesced/change-then-revert; atomic replacement/root recreation/restart; overflow/eviction; owner death without a write; absent-root no-initialization; bounded cancellation with no task-owner signal or leaked child; and explicit wait/cursor/document bounds.

Swift must keep the last acknowledged cursor, cancel only its watch invocation, generation-fence stale responses and start a new baseline after runtime/root/environment changes. Current polling admission intentionally drops ticks while a refresh is busy. A future cursor-backed change signal must instead remain pending until a subsequent public refresh claims it, or use a coalesced follow-up admission path; merely swapping sources while discarding busy invalidations can lose the only change signal. Require a deterministic change-arrives-during-busy-refresh regression before watcher adoption. This bounded admission adaptation belongs with the later driver, while paging, facts and action barriers remain unchanged. Each wait and each authoritative refresh retains its own fresh compatibility/capability checks. A failed wait reconnects conservatively with bounded backoff; no handshake cache, retry storm or mutation replay. Tests need independent publication/continuity oracles, not just the producer's own generation claim.

## Timing and ownership gate

Bring this brief into the separately assigned Rust architecture/public-observation work; it is not part of current internal-store R02-A scope. The canonical contract owner at implementation time must approve and commit specification/capability/fixtures/tests first: **HarflowMCP before accepted O04 transfer; HarflowEngine afterward**. If implemented pre-transfer, Python owns the accepted producer contract and Rust implements that same contract; no competing Rust schema. If deferred until after transfer, later implementation must not depend on retired Python.

After accepted producer delivery, qualify the exact intended artifact/capability, vendor the complete byte-identical fixture bundle, add a typed ctl watcher driver and replace polling at the existing Mac observation seam. Independently qualify Python/Rust continuity/fault behavior for claimed platforms. No production switch, platform claim or owner acceptance is inferred from this plan.

## Subsequent producer handoff

The owner subsequently requested a separate bounded Cursor handoff for a possible0.0.9 public watcher, while retaining public polling in M03. That proposal and copy-ready prompt live outside product repositories. The owner will send it to Cursor; this receipt does not dispatch that agent, accept the proposed API or authorize implementation/publication. The same canonical-owner and later Rust-adoption gates above still apply.
