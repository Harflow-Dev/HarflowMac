# ST05-B - launch enrollment

Status: implemented with fixture and fake-runner tests. Not runtime-qualified, has no callers, and nothing enrolls in production. This step does not provide durable delivery.

## Scope

Step 2 of ST05, narrowed to launch enrollment in MonitorCore. `conversationLaunch(_:profile:)` and `conversationResume(taskID:text:profile:maxTurns:)` start a task with an explicit `--conversation-profile`. There is no repository, durable store, UI, local qualification table or workflow commit. `RunRequest`, `CtlClient.run` and `CtlClient.resume` are unchanged, and the shipped launch path enrolls nothing.

The owner told the coordinator "keep them working" and delegated engineering details to the coordinator, who directed this step and this narrowing on 2026-11-07. `docs/migration-plan.md` still reads that no ST05 implementation is assigned.

## Engine facts this rests on

HarflowMCP 0.0.11, by reading its source and documentation, not by running it.

- Enrollment happens at launch. `conversation-prepare` refuses for a standalone task launched without a profile, so prepare does not enroll one.
- Admission is an exact lookup on runtime and profile fingerprints, including version, binary hash and resolved path. No public command answers this before a launch, so the app attempts the launch and reports the answer.
- A refused launch can leave a record and a process behind, and the same exit 1 `unsupported` code covers both that and a launch where nothing happened.
- `run` has no request id, so a launch has no idempotency key.
- `resume` returns a new successor task id, not the input id.

## Classification rules

- `.launched`: exit 0, validated envelope with a usable task id.
- `.notDispatched`: no command launched (probe failure, missing capability, cancellation before launch, process launch failure), or exit 2 with a validated `usage` envelope.
- `.engineError`: validated envelope with an `error` object at exit 1. **This does not prove that no record exists.** There is deliberately no `.refused` case.
- `.uncertain`: everything else. A validated `unknown` document at exit 3 keeps the engine's message as `.processFailure(.unknownOutcome(message:))`. Exit 2 with no validated envelope stays uncertain, including `invalid choice` on stderr.

A launch is never retried automatically, and no API retries it. The `conversation-delivery.v1` capability is a floor and does not prove qualification. The selected profile is a required parameter, so this route cannot report `.launched` for a task started without one. Selected settings are rendered as given: nothing is removed or changed to fit the qualification matrix.

Launch and resume use the existing 75-second start timeout. Send and control keep 120 seconds, and the 1 MiB stdout cap applies to all of them.

## Deferred to step 3

`ConversationDeliveryRepository`, the durable intent store, `TaskInfo.conversation`, publishers and module wiring are deferred, because they would be a state machine with no caller, designed ahead of step 3 and the G-QUEUE decisions. Review of that store left these findings open, and step 3 inherits them:

1. **Reconcile rule.** No workable rule exists for workflow targets. Prepare can write a binding, the app cannot see the binding, and the conversation id is deterministic, so a re-enrolled fresh ledger passes an id check and reads as absent. A starting point is to refuse reconcile for workflow-owned targets and stay uncertain.
2. **Attempt-state table.** Probe, capability and cancellation checks run inside the exchange, after any write made before dispatch. An explicit table is needed, covering a failed write, a return to prepared, a first-attempt engine error and state on load.
3. **Byte comparison on retry.** Records holding mutable state make a whole-file comparison report a false conflict on a legitimate retry. Compare the immutable request body.
4. **Actor reentrancy.** A private actor suspends across store work and process runs, so check-then-dispatch is not atomic. A per-request in-flight set must cover send, control, resolve and reconcile.
5. **Engine dedupe of repeated control requests.** Unverified whether the engine dedupes a repeated promote or cancel, which decides whether retry after an uncertain outcome is safe for control.
6. **Cap wedge.** A count cap with no eviction and explicit-only discard wedges without a UI.
7. **Accepted handling.** Without a stored receipt, a retry that finds an accepted record cannot build an accepted outcome, and marker-write and removal failures are undefined.

Step 3 also needs decisions on which tasks enroll, who picks the profile, what the composer does with non-matching selections, offered cap values, Vibe model disclosure, and refused, unknown and locked draft presentation under G-QUEUE and G-NEWTASK-ADVANCED. `.engineError` and `.uncertain` carry no task id, so launch leftovers need a recovery surface.

## Evidence

Tests are in `ConversationDelivery/ConversationLaunchTests.swift`. Vendored `ctl-launch-*` fixtures are read through the manifest, unchanged. No fixture covers a profile flag or a launch `unsupported` refusal, so those cases are synthetic and named as such. No real engine binary ran.

MonitorCore through the guarded runner: 671/671 tests in 77 suites. SwiftFormat reported nothing to format. SwiftLint 0.57.1 reported no violations; CI pins 0.63.2. Both guards passed. Strict gates on `8e51185`, one package at a time, from 09:41 to 10:00 with a peak one-minute load of 18.5: MainWindowFeature 260/260 suites and 1,941/1,941 tests, HfCommon 18, HfUI 239, HfUtilities 19, HfRepository 520, MonitorCore 671, MenuBarFeature 88, SettingsFeature 87, Harflow 119. The Python tooling tests passed 235 and the Release build passed on `7642014`, one commit before these documentation-only changes.

## Limits

- Enrollment against real harnesses is unmeasured, so this establishes no qualification of any runtime or profile.
- Whether a real launch through this route is admitted on this machine is unknown.
- The engine's `qualify_saved_source` path reads as refusing detached callers until qualification receipts exist, which bears on enrollment after a restart. It was not exercised.
