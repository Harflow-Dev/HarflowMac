# M01 — Public capability and private-coupling inventory

Planning evidence for [M01](M01.md), 2026-11-04. No implementation or acceptance.
Native source: `9175d46baf8c8507eb7cec81d21b90225103f557`. Canonical candidate producer: `b0185be855fd13acc94cb2d2008400d285d15df2`. Paths below are relative to the named repositories. `MC` = `HarflowMac/macos/HfCore/MonitorCore/Sources/MonitorCore`; `Repo` = `HarflowMac/macos/HfCore/HfRepository/Sources/HfRepository`; `Engine` = `HarflowMCP/src/harflow_mcp`. Native feature paths are under `HarflowMac/macos/HfFeatures/MainWindowFeature/Sources/MainWindowFeature`.

## Retained and simplified capabilities

| Capability | Public operation and exact source evidence | Outstanding disposition / adoption |
| --- | --- | --- |
| Task repository/harness/model/access/prompt; effort/turn/caller options | `run`; `MC/CtlClient.swift:223`; `Engine/ctl.py:395,1466` | Core accepted; advanced options Proposed |
| Enforcement preview | `permission-preview`; `Engine/ctl.py:440`; `MC/CtlClient+Qualification.swift:7` | Proposed keep; distinguish preview from enforced facts |
| Harness/model/availability/qualification | `backends`, `qualify`; `MC/CtlClient.swift:189`, `CtlClient+HarnessQualification.swift:7`, `CtlClient+Qualification.swift:18`; `Engine/ctl.py:200,205` | Report selected-engine cells; exact version/platform qualification separate |
| Running/Recent, task headers/history | `list`, `status`, `status-batch`, `task-list-page`, `workflow-list-page`; `MC/CtlClient.swift:127,167,174`, `HistoryPage.swift:68,83` | Flat rows do not remove lineage, bounded cursors, counts/history completeness |
| Prompt/title/transcript/tool activity/summary | `task-prompt`, `task-events`; `Engine/ctl_task_reads.py:90,106`; contracts:669 | Native still private-file based; no typed production references to new commands found |
| Queue/Send now/cancel queue | `send`, `send --now`, `cancel-message`; `MC/CtlClient.swift:196,201,206`; `Engine/ctl.py:231,240` | Queued/refused/unknown/unsupported distinct; no replay |
| Continue | Native `resume`, `MC/CtlClient.swift:227`; producer fresh-session `continue`, `Engine/ctl.py:481,1555` | Explicitly decide v2 Continue mapping; resume and fresh continuation are not interchangeable |
| Cancel task/group lane | `cancel`; `MC/CtlClient.swift:210`; `Engine/ctl.py:246,1115` | Real cascade, surviving earlier-turn children, unknown exit and incomplete drain remain visible |
| Copy ID/resume command | ID/status; native `TaskDetailVM.swift:525` | Local copy only; no takeover authorization |
| Changes | `task-changes`; `Engine/ctl.py:169`, `ctl_task_reads.py:115`; contracts:869 | Delivered producer, native adoption missing; no native Git fallback |
| Artifacts | `task-artifacts`, `workflow-artifacts`; `MC/TaskArtifacts.swift:83`, `WorkflowArtifacts.swift:107`; `Engine/ctl.py:124` | Metadata/stat references; no implied content validity/authorship/copy authority |
| Events right pane | `task-events`, workflow activity | Raw sheet → pane Proposed simplify; keep normalized event provenance |
| Approvals | `approval-list/get/respond`; `MC/CtlClient+CallerApprovals.swift:58,73,77`; `Engine/ctl.py:377,385` | Exact action/revision/digest/channel; monitor caller response needs `caller-approvals.monitor-respond.v1` |
| Needs you/questions/recovery | `workflow-status/resume/recover`; `MC/WorkflowClient.swift:13` | Decision ID differs from attention checkpoint; current ownership/token required |
| Notifications | `interaction-events`; `MC/InteractionEvents.swift:64`; `Engine/ctl.py:133`; contracts:1860 | Root-scoped cycle/seen bookkeeping, bounded dedup; platform delivery separate |
| Workflow list/run/preview/status/detail | `workflow-list/start/preview/status/detail`; `Repo/Workflow/WorkflowRepository.swift:55`, native `Workflow/WorkflowVM+LaunchPreview.swift:53,98`, `WorkflowRunPolling.swift:59,168` | Definitions separate from running executions; launch uncertainty retained |
| Editor/save/validation/conflicts | `workflow-get/validate/save`; `MC/WorkflowClient.swift:36,47`, `Repo/Workflow/WorkflowRepository.swift:68,73` | Expected revision/ID conflicts; preserve unsaved edits |
| Generate/Edit with agent | `workflow-build/builder-followup`; native `Workflow/WorkflowVM+Generate.swift:31`; native `TaskDetail/TaskDetailViewRepository.swift:137` | S09 excludes proposal/draft/conflict qualification; explicit proposal review |
| Delete | `workflow-delete`; native `Workflow/WorkflowVM.swift:390` | Confirm deletion; existing run snapshots retained; Duplicate removed |
| Nodes/on-demand/parallel/activity | `workflow-inspect --view activity`, detail/status; native `Workflow/WorkflowNativeActivity.swift:106` | Dynamic workflow client currently lacks independent `workflow-live-activity.v1` gate; M03 must establish it |
| Pause/resume/cancel/recover | Dynamic `workflow-*`; `MC/WorkflowClient.swift:13`; `Engine/ctl.py:507,1606` | Current scheduler/checkpoint scope, unknown/refusal; reads never recover |
| Node/orchestrator messages | `workflow-send/cancel-message`; native `Workflow/WorkflowVM+ActivityMessages.swift:45,60`; `MC/WorkflowClient.swift:29` | Proposed keep, design pending |
| Revise goal | `workflow-revise-goal`; native `Workflow/WorkflowVM+Goal.swift:16`; `Repo/Workflow/WorkflowRepository.swift:58` | Proposed keep; conflict and unknown control preserved |
| Parallel group lanes/composer/Cancel all | Task headers/events/send/cancel operations above | No native group-start API required: group created only through MCP; visible-column leases and exact cancel scope retained |
| Slot/queue observation | `resources`, `slot status`; `MC/ResourceSlotsClient.swift:7,20`; `Engine/ctl.py:267,295` | Administration ctl/MCP-only Proposed; disabled/unsupported/permission distinct |
| Statistics/range/cost/model | `statistics-page`; `MC/StatisticsModels.swift:101`; `Engine/ctl.py:146`; contracts:565 | Complete one generation before authoritative aggregation; null unknown; retained history only |
| Runtime/store status | Managed runtime qualification + public `state-inspect`; `MC/StateRecovery.swift:122` | Status accepted; recovery UI scope Undecided |
| Store inspect/backup/reset | `state-recover`; `MC/StateRecovery.swift:132`; `Engine/ctl.py:113` | Existing API does not settle future UI/Rust fresh-store policy |
| Harness registration | Separate `harflow-setup status/install/remove`; `MC/SetupClient.swift:102,114` | Explicit setup actions; not product engine MCP fallback |
| Global allowlist | `mcp-allowlist`; `Repo/MCPAllowlistClient.swift:11`; `Engine/ctl.py:497` | Human-only future-session backend-specific configuration; no task-wide approval |
| Worktree/scratch observation | `worktree-list`, `scratch list`; `Engine/ctl.py:346,365` | UI Undecided; engine retained |
| Worktree/scratch cleanup | `worktree-remove`, `scratch clean`; `Engine/ctl.py:349,367` | Human-only; no assumed native administration scope |
| Appearance/behavior/menu/window/deep links/single instance | Native preferences/shell; `macos/Harflow/AGENTS.md`, `App.swift` | No engine operation needed; engine-derived facts still ctl-only |
| Usage ordering | Existing `agentUsage.v1`; S02 preference map | Proposed per-repository choices; no count/history transfer |
| Diagnostic simplification | Public run/detail/inspection projections above | Proposed reduction in presentation only; preserve recovery/authority truth |

No clearly missing producer operation was established for these core retained capabilities. A command name alone does not prove adequate semantics or execution qualification. No ctl addition is authorized by this inventory.

## Private persistence and directory coupling

| Source | Current dependency | Required public replacement |
| --- | --- | --- |
| `MC/Titles.swift:20` | First event-line read, bounded256KiB; constructs task event path | Header/status title + `task-prompt` authoritative/preview/integrity distinctions |
| `MC/EventPages.swift:40,115` | FileHandle, byte offsets/anchors | `task-events` opaque cursors, capture/gap semantics |
| `MC/Tail.swift:90,119,241` | File reads/descriptor DispatchSource/LineTail | Bounded public observations, cancellation/disposal |

Later note: `MC/EventPages.swift` and `MC/Tail.swift` were removed at the commit "Remove unused engine-file readers from MonitorCore" (2026-11-13); the engine is read only through `task-events`.
| `Repo/EventStream/EventStreamRepositoryImpl.swift:48,311,316` | Constructs event path, local tail/history/summary | Public prompt/events, generation-fenced off-main folding |
| `Repo/TaskList/TaskListRepositoryImpl+Compatibility.swift:71` | Starts tasks directory watcher after compatibility success | Public list/page/status reconciliation after fresh handshake |
| `Repo/TaskList/DirectoryWatcher.swift:11` | FSEvents storage-layout dependency | Public polling scheduler/backoff; no engine directory watch |
| `MC/Events.swift:3,11` | Physical-line assumptions in documentation | Normalized event identity/version independent of persistence |

Old watcher latency0.3s, throttling and 10/30/60s safety scheduling (S02) are behavior evidence, not a mandate to retain private access. Replace triggers without weakening freshness, stale-response rejection or observation disposal. Retain logical reading anchors and bounded visible-lane observation. Preference/notification-seen storage belongs to the app, managed-runtime acquisition/receipt files belong to its runtime manager, and private0700/0600 temporary CLI payload files are explicit inputs: none is a license to read engine task persistence, nor a reason to delete valid app-owned I/O.

## Minimum semantics to ratify with SB1

Canonical `HarflowMCP/docs/contracts.md` at the candidate source is authoritative:

| Contract area | Bounds / provenance / refusal |
| --- | --- |
| Handshake | Independent ctl/setup/event v1; selected runtime/platform/root; fresh probe before each operation, same HOME/cwd/environment; N observations cost2N process launches; response independently validates (S05:76) |
| Events (:686) | Direct caller; 1–200 lines, 1MiB scan,262144-byte document; ascending; opaque≤2048-character identity/generation/anchor cursor; open/settling/final/incomplete/unknown/unavailable. Final≠complete history. Invalid/expired cursor resets newest and invalidates derived history |
| Prompt (:770) | Bounded UTF-8; available/preview_only/integrity_failed/unavailable; preview not authoritative |
| Successors (:845) | Recorded direct successors only, pending launches absent; filter-bound keyset cursor,1–100 rows,128KiB row; sparse unindexed scan means no tight polling |
| Live workflow activity (:814) | Verified direct caller; managed/MCP settled-only; seq page; not_started/unavailable/available; stop only settled plus drained |
| Changes (:869) | Stored bounded capture, direct caller;262144-byte document; snapshot cursor expiry→first page; pending/incomplete/unavailable/not_captured/unmerged_unknown; shared-checkout observations not authorship; no Git/content fallback |
| Approvals (:235) | Exact action/current revision/digest/channel/owner; unknown reason not actionable; decision/delivery/execution distinct; submission timeout→read-only refresh, never resubmit |
| Statistics (:565) | All pages one generation for authoritative aggregates; cost/usage completeness separate; null unknown; no all-time beyond retention |
| Messages/control (:1602) | Preserve exact queue/delivery/cancel outcome, current ownership/checkpoint; uncertain delivery is not permission to resend |
| Capability additions | task-event-page.v1, task-prompt.v1, task-successors.v1, workflow-live-activity.v1, statistics-cost-model.v1, task-changes.v1; each independently required by its operation, alongside preexisting operation predicates |

## Bounded producer-first follow-up proposals

These are discovery/specification briefs, not claims an API is missing or implementation assignments:

- **M03-C01 observation adoption audit:** type every retained projection, cursor/capture/retention state and title/summary source; replace every listed engine-private read/watch; determine any absent field using exact public evidence. Include disposal, stale generations, unknown event kind and unsupported operation. Native owner + MCP contract lead.
- **M03-C02 Continue semantics:** decide resume versus fresh-session continue per v2 action, including capability/launch exit, queue consumption and conversation successor identity. No command substitution by label. Owner decides behavior before adapter implementation.
- **M03-C03 live workflow authority/gates:** map each activity/checkpoint/node read and caller role; enforce live capability at dispatch and preserve settled-only managed restrictions. Include caller-loss/unknown/refusal evidence.
- **M03-C04 only if a semantic gap is proven:** MCP canonical spec first, explicit provenance/authority/bounds/cursor/unknown/refusal and capability, canonical fixtures + independent tests, immutable producer commit; then full byte-identical Swift vendoring and exact Rust adoption. No MCP app client or persistence workaround.

S03 exact MCP partition remains Proposed: eight candidates deferred are `subscribe`, `unsubscribe`, `subscribe_workflow`, `unsubscribe_workflow`, `get_task_notifications`, `get_workflow_notifications`, `recent_limit_hits`, `workflow_limit_hits`;47 is the complement of the55 snapshot only after ratification. Historical ctl69/77 remains Proposed (deferred takeover/takeover-attach/limit-hits/workflow-limit-hits/workflow-notifications/workflow-migrate; state-inspect/state-recover undecided); additive S04 commands require a current per-path reconciliation, not count-based acceptance.

## Complete advertised capability inventory for SB1 review

Exact producer list: `HarflowMCP/src/harflow_mcp/wire_contracts.py:22` at candidate source. Advertised does not mean qualified or automatically in an accepted subset. This table includes all21 capabilities; final M03 dispatch audit must verify each predicate rather than assume advertisement equals consumer gating.

| Capability | Operation / authority allocation |
| --- | --- |
| `ctl.v1`, `setup.v1`, `events.v1`, `version-info.v1` | Base public command/setup/normalized event/handshake compatibility; independently validated formats, not replacement for additive operation gates |
| `interaction-events.v1` | Bounded interaction notification feed; `MC/InteractionEvents.swift:67` requires it |
| `workflow-shared-interactions.v1` | Shared question answering/caller-loss handover; current-owner and exact decision semantics; canonical contracts:1194; native constant `WireContracts.swift:24` does not alone prove all dispatch gates |
| `workflow-attention-checkpoints.v1` | Monitor resume/recover checkpoint projection/submission; `MC/WorkflowClient.swift:28` requires when checkpoint/guarded monitor control; never mix question decision ID with attention checkpoint |
| `phase-slots.v1` | `resources`, `slot status`; `MC/ResourceSlotsClient.swift:8,21`; layout-disabled/unsupported state distinct, no admin UI grant |
| `state-recovery.v1` | `state-inspect`, `state-recover`; `MC/StateRecovery.swift:150`; read-only inspection distinct from explicit destructive recovery |
| `caller-approvals.monitor-respond.v1` | Caller-owned exact approval response from monitor; `MC/CtlClient+CallerApprovals.swift:84`; no task-wide grant |
| `statistics-page.v1` | Base statistics paging; `MC/StatisticsModels.swift:104`; complete generation required |
| `backend-qualification.v1` | Backends/qualification/run-plan discovery; `MC/CtlClient+HarnessQualification.swift:8`, `CtlClient+Qualification.swift:24,41`; actual CLI/version qualification still required |
| `messaging.v1` | Task send/cancel-message, workflow send/cancel-message and monitor builder flow; `MC/WorkflowClient.swift:30`, canonical contracts:1602 |
| `task-event-page.v1`, `task-prompt.v1` | New bounded direct-caller event/prompt reads; native typed adoption pending |
| `task-successors.v1` | Recorded successor filter on task-list-page; pending launches absent |
| `workflow-live-activity.v1` | Verified direct caller live activity; native dynamic workflow gate adoption pending |
| `statistics-cost-model.v1` | Cost/model/coverage fields in statistics-page; null unknown; native typed adoption audit required |
| `task-changes.v1` | Stored bounded diff reads; native typed adoption pending |
| `limit-hits.v1`, `workflow-limit-hits.v1` | Current Python advertised capabilities; client/Rust limit projections deferred by policy, exact surface still Proposed; not silently deleted from Python |
