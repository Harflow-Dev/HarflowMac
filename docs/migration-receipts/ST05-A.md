# ST05-A - typed conversation delivery adapters

Status: step 1 implemented with fixture and fake-runner tests. Not runtime-qualified, has no callers, and owner confirmation of the assignment is pending.

## Scope

Step 1 of ST05 only: typed adapters in MonitorCore for the HarflowMCP 0.0.11 `conversation-delivery.v1` ctl contract (`conversation-prepare`, `conversation-send`, `conversation-control`). There are no callers, no UI, no enrollment flow, no repository adapter and no workflow commit. Legacy `send`, `sendNow`, `cancelMessage` and the work message queue are unchanged.

The capability string `conversation-delivery.v1` comes from `wire_contracts.CAPABILITIES` in HarflowMCP; the prose list in `docs/contracts.md` is stale and is not the source.

## Classification rules

- `.accepted`: exit 0, validated envelope with `result`, receipt identities matching the request. For a plain task target, a non-null `workflow_run_id` or `activation_id` is an identity mismatch in both send and control receipts.
- `.notDispatched`: no command launched (input file failure, probe failure, missing capability, cancellation before launch, process launch failure), or exit code 2 together with a validated envelope whose error code is `usage`. Parser text on stderr is not proof: the process runner ignores the termination reason, so a signal after durable admission can also read as exit 2.
- `.engineError`: validated envelope with an `error` object at exit 1. This is not evidence of non-admission.
- `.uncertain`: everything else after launch, including timeouts, unreadable output, envelope incompatibility, oversized output, contradictory envelope and exit, and receipt identity mismatch.

## An engine error is not evidence of non-admission

The engine catches exceptions after durable admission and reports the same error envelope. In HarflowMCP v0.0.11:

- `conversation_delivery.py` and `conversation_api.py`: non-native send and promotion drain after the durable ledger write, so a drain failure surfaces as an error after admission.
- `conversation_workflows.py`: workflow delivery scheduling can fail after its commit.
- A retry of a message already evicted from the retained window refuses with `request_expired`, which says nothing about the first attempt.

The adapters therefore keep `error.data` verbatim, offer no allowlist of codes that imply safe retry, and leave presentation to a later step.

## Other decisions

- Prepare uses a 60-second timeout, above the engine's 30-second session lock wait. Its 32 MiB stdout cap is checked before any JSON parsing; it bounds decoding, not memory, because the process runner buffers output.
- Send and control use a 120-second bound and a 1 MiB stdout cap. There is no automatic retry and no cancellation guard after launch.
- Projection decoding fails closed on required nested fields the engine always emits: message `source_generation`, `source_turn_id`, `source_epoch` and `original_target_task_id` (nullable), all accounting fields (cost values nullable but present), and runtime fault code, generation and turn id when a fault is present. Conditionally emitted fields such as `progress`, `destination`, `receipt` and `interrupt_intent` remain optional.

## Limits of the evidence

Fixture and fake-runner evidence only. No runtime qualification was performed, and live behaviour for Mac-launched tasks is unmeasured.

## Authority

This work ran overnight on the coordinator's assignment. The planning documents conflict on whether ST05 is assigned, and the owner has not yet confirmed it. The code is additive and has no callers.

## Gate results

| Check | Result |
| --- | --- |
| MonitorCore guarded aggregate with `HARFLOW_NATIVE_BENCHMARK=1` | Passed: 628/628 tests in 76 suites |
| HfRepository and Harflow guarded aggregates | Passed: 520/520 and 119/119 |
| Format, strict lint, legacy-name and private-reference guards | Passed |

All 33 `ctl-conversation-*` fixtures are consumed, and a catalogue test fails if a new one is unhandled. Cases the fixtures lack, such as engine errors with `data`, post-admission errors and every transport fault, are labelled synthetic in the tests. The plan and code each ran two review rounds with three reviewers; all findings were fixed or adjudicated.

The prepare timeout of 60 seconds deliberately differs from the plan's quick timeout, for the reason given above.
