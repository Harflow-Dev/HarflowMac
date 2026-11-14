# MonitorCore

Foundation-only values and I/O for Harflow wire decoding, public event pages, lineage, process execution, and environment construction. The package stays in Swift 5 language mode for its process-table concurrency internals; see [architecture rules](../../AGENTS.md).

## Compatibility

The canonical [wire specification](https://github.com/Harflow-Dev/HarflowMCP/blob/main/docs/contracts.md) is engine-owned. The consumer validates Harflow product identity, format, integer wire version 1, and stable product-version syntax before interpreting payloads. Live ctl/setup answers and compatibility probes require the selected major/minor release line; normalized events retain historical writer versions as provenance.

`RuntimeCompatibilityContext` carries the explicit lexical absolute state root. `VersionInfoClient` runs the selected `harflow-ctl version-info --json` directly through `ProcessRunning`, with a bounded strict document and no cache. Ctl commands and setup actions probe immediately before each operation with the same effective HOME/environment and working-directory policy. Setup probes its paired control executable, never PATH. Darwin/arm64 and the operation's advertised contract/capability are required. Lexical comparison preserves case and does not resolve symlinks; aliases that do not normalize equally safely refuse.

Tests vendor exact engine-owned fixtures under `Tests/MonitorCoreTests/Resources/ContractsV1`, including the engine manifest and its SHA256 digest. The package has no sibling-repository dependency or fixture download step. These envelopes do not establish storage ownership or runtime authenticity.
The [fixture provenance](../../../docs/contract-fixtures.md) pins the producer commit,
manifest digest and scope separately from the managed runtime pin.

## Caller approvals

Approval responses preserve the engine's structured refusal data and decode known owner and refusal values without authorizing unknown values. Caller-owned responses require `caller-approvals.monitor-respond.v1` on their fresh operation handshake. A separate capability read informs presentation only; it never authorizes submission. Monitor-owned responses retain compatibility with older engines. `TaskInfo.awaitingDecisionCount` is optional and distinguishes missing legacy data from an authoritative zero.

## Shared workflow interactions

`WorkflowInteractionState.responders` preserves explicit response channels while keeping ownership separate. Missing responders use legacy eligibility. `WorkflowInteractionReceipt` decodes durable engine history and `ToolError.workflowInteractionWinner` retains a structured losing-response receipt. Approval winners preserve their request/task identity, decision, responder and timestamp independently. Unknown or incomplete attribution never becomes a caller or Monitor answer.

## State recovery

`CtlClient.inspectState()` and `recoverState(inspection:)` require the pure handshake’s `state-recovery.v1` capability before launching public ctl commands. Inspection and completion receipts validate the selected root and operation identity. `ToolError.structuredRefusal` retains additive engine `error.data`, including partial-backup evidence, while legacy errors preserve their existing shape. Store refusal never changes executable qualification.

## Build and test

```sh
swift build --package-path macos/HfCore/MonitorCore
HARFLOW_NATIVE_BENCHMARK=1 python3 scripts/test-swift-package.py --package macos/HfCore/MonitorCore --mode aggregate
```

Complete malformed or incompatible event records make activity and summary reads explicitly unavailable. An incomplete trailing write is deferred until a newline completes it; unknown additive event kinds remain readable.

## Managed runtime

`ManagedRuntimeLayout` derives executable storage and the selected `.harflow` store from an injected home without reading history. `ManagedRuntimeInstaller` performs bounded HTTPS acquisition, verifies pinned bytes, installs only locked binary wheels offline under a private pip environment, qualifies the relocated generation, and atomically activates it under a permanent process lock. Completion receipts bind exact engine version, specification, generation, selected store, and observed engine SHA256/yanked metadata. Existing generations are never replaced or collected. The app bundles the specification as a SwiftPM resource; [maintenance and trust details](../../../docs/managed-runtime.md) describe its inputs.

## Statistics history

`CtlClient.statisticsPage` reads bounded typed `StatisticsPage` / `StatisticsFact` values through the public ctl envelope, requiring `statistics-page.v1` on each operation. Unknown states, unsupported capabilities and malformed pages remain unavailable. Token accounting and duration qualification are independent; legacy absent accounting never becomes zero.

## Task prompt reads

`CtlClient.taskPrompt(taskID:maxBytes:)` requires `task-prompt.v1` on a fresh
selected-runtime handshake for each read. `TaskPromptResult` preserves the engine's
available, preview-only, integrity-failed and unavailable states independently of
UTF-8 byte counts, truncation, completeness and integrity. Text is verbatim; raw
additive fields and explicit prefix-resolution provenance remain available.
Malformed known fields, unknown states and mismatched task identity fail decoding;
transport/capability refusals remain failures rather than successful empty prompts.
The text ceiling is1...131072bytes (default65536); JSON escaping may make the
response exceed the separate event-page ceiling. No prompt file is read by this
adapter. This foundation does not change the managed runtime pin or rendered
prompt/activity consumers.

## Public task-event pages

`CtlClient.taskEvents` requires a fresh selected-runtime handshake for both ctl
and event contracts and `task-event-page.v1`. Request enums keep origins/cursors
and all/default/explicit filters exclusive. Pages retain public normalized raw
records, historical writer provenance, opaque cursors, accounting spans/gaps,
skipped windows and lifecycle evidence. Repeated or regressing sequence values
stay in file-array order; they are not global identities. Normalization loss and
oversized stubs never acquire legacy parser defaults or an automatic TaskEvent
projection. A final log is not proof of complete history or a drained page chain.

The task-events document ceiling is checked before JSON parsing; this does not
cap the baseline process runner's raw stdout capture or total heap use. The
per-record admissibility meter uses a conservative unescaped serialization lower
bound, not ASCII-escaped wire size. Native explicit-filter admission is limited
to200names/16KiB UTF-8; cursors remain opaque and at most2048Unicode scalars.
The application's former private activity and cumulative-summary file readers are deleted;
events are read only through these public pages.

## Task changes

`TaskChanges*` decodes the `task-changes.v1` listing and text chunks on `CtlClient`, with
`TaskChangesListingBuilder` and `TaskChangesTextAssembler` merging pages and chunks. `isComplete`
alone does not mean no changes: only `hasNoChanges` does, because a missing repository, a capture
reason or reported conflicts all stay complete. Unknown states remain open values. `HfRepository`
reads them through `TaskChangesRepository`, and the task screen's Changes tab presents the listing;
text chunks are not read by any screen yet.

## Conversation delivery adapters

`ConversationDelivery/` holds typed adapters for the `conversation-delivery.v1`
ctl contract: `conversationPrepare`, `conversationSend` and `conversationControl`
on `CtlClient`, immutable request values, projection and receipt decoders, and an
outcome type that distinguishes not-dispatched, engine-error and uncertain
results. There are no callers and no UI. Evidence is the vendored contract
fixtures and fake-runner tests only; nothing here is qualified against a running
runtime. An engine error is not evidence that a message was not admitted, and
the only post-launch proof of non-dispatch is exit code 2 with a validated
envelope whose error code is `usage`.

`conversationLaunch(_:profile:)` and `conversationResume(taskID:text:profile:maxTurns:)`
start a task with an explicit `--conversation-profile`, returning a
`ConversationLaunchOutcome`. They also have no callers, and provide no durable
delivery. An engine error from a launch does not prove that no task exists, because a
refused launch can leave a record behind. A launch has no idempotency key and is never
retried automatically. Qualification is decided by the engine at launch; this package
holds no qualification table.


## Continue client foundation

`CtlClient.continueTask(_:)` sends the base `continue SOURCE` operation after one fresh
handshake advertises both `task-continue.v1` and `task-successors.v1`. It returns the existing
`ConversationLaunchOutcome`; `.launched` acknowledges acceptance and may describe a launch
still pending resources, never completion. It sends no conversation profile or optional launch
flags. Source prefixes are resolved by the engine.

The phase-aware transport retains structured engine errors and uncertainty after possible
dispatch, including timeout or malformed responses. It never retries. A result from this
invocation cannot clear uncertainty retained from an earlier one, and an empty recorded-successor
page cannot establish that no pending launch exists. Launch envelopes must contain exactly one
of result, error or unknown. The shared continuation owner and standalone task screen now consume
this client; evidence remains vendored 0.0.14 fixtures and fake runners, not exact-runtime qualification.

## Pending-launch client foundation

`taskPendingPage(limit:cursor:)` and `taskPendingStatus(taskID:)` read bounded public
pending-launch evidence after a fresh `task-pending-launch.v1` handshake. Each read
checks the 128 KiB document ceiling before parsing; this does not bound process stdout
capture. Single-page metadata never becomes task status, cancellation permission,
settlement or safe replay. Unknown states/dispositions retain diagnostic evidence
without trusted labels. `hasUnsupportedObservations` keeps client comprehension
separate from producer coverage: a producer-complete page can retain future values
and healthy neighbors while remaining ineligible to complete a comprehended inventory.
Recorded lookup requires a later ordinary status read.

`stopPendingLaunch(_:)` requires both pending-launch and cancel-cascade capabilities
in one fresh handshake. It uses the phase-aware mutation transport without retry;
engine errors and post-dispatch failures retain uncertainty. A successful receipt
requires a valid matching identity and cascade observation; corrupt/missing observations
remain uncertain. Raw cascade diagnostics are retained without logging. Only qualified
complete, untruncated target evidence with a stopped state and settlement/not-started
basis proves stopped. Acknowledgement alone does not. Same-ID spawn races use ordinary
cancel semantics, without an atomic generation precondition. These clients have no UI
or inventory owner and do not change the selected engine pin or certify runtime support.
