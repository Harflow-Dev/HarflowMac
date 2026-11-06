# M01 — Native code to v2 and missing-state inventory

Planning only, 2026-11-04; see [M01](M01.md). Source native HEAD `9175d46baf8c8507eb7cec81d21b90225103f557`. No specimen, approval or implementation created.

## Design provenance

Approved containing commit **A** = `3643d083700be4032c93237813b573d04bab6ab1`; builder-pane amendment **B** = `34c3b0576e221d17b1096136db6c5d0fbb4c5000`. All listed product states require `/light` and `/dark`; `/system` must follow native appearance changes. Paths below are in HarflowDesign `v2/scripts/`. Thirty product states are enumerated below, alongside component references. Browser1280×800 approval does not prove native pixels/chrome, focus, keyboard or accessibility.

Current Design HEAD `9cfe4ce81789ed87c7ee40c10802ff0e3b2c7552` includes later **C** = `acd63f970293ed150a4ade88fe97cf5d4e2aa4af`, changing editor/run specimens to locked orchestrator first in Standalone. Current inventory records that rule; approval record does not identify that immutable amendment. **Proposed:** owner confirm C as approved and reconcile ledger citations before consuming it. Otherwise pin A/B approved specimens with the exact deviations recorded. This is a provenance question, not a finding that the rule is unwanted. Task template last changed at `24958cfb155cc1149b527aba725d90931068abd0`, contained in approved A. Citation policy wants last-changing commit plus approval provenance: do not claim current HEAD universally approved or blindly cite A for changed editor/run files. No hosted deployment was verified.

Native paths abbreviated below are under `HarflowMac/macos/HfFeatures/MainWindowFeature/Sources/MainWindowFeature`, unless a different package is named. A “gap” blocks dependent design implementation, not unrelated accepted Rust schema work.

| Native source / capability | Disposition | Pinned design path / complete product state routes | Missing state or decision |
| --- | --- | --- | --- |
| `NewSession/NewSessionVM.swift:103,238` prompt/repository/harness/model/access/options | Keep core Accepted; advanced Proposed | A `screens-new-task.js`: `new-task/default`, `new-task/harness-menu`, `new-task/sidebar-collapsed` | Advanced effort/turn/caller options, enforcement/qualification unknown/unavailable; validation/start refusal/unknown |
| `Sidebar/SidebarView.swift:171`, `SidebarVM.swift:214,354` nested Today/Earlier/search/filter | Simplify flat Running/Recent; remove search/filter Accepted | A same three new-task states | Older paging, retention, selection/reconnect/read failure; conversation successor identity still required |
| `TaskDetail/TaskDetailView.swift:23`, TimelinePaneView/Activity/ToolRow | Remove Activity/Summary/Prompt tabs; keep prompt-first transcript, summary/tools/live state Accepted | A `screens-task.js`: `task/running`, `task/approval`, `task/done`, `task/failed` | Timed-out/cancelled/settling/unknown; bounded history, capture/read failure, anchoring/follow |
| `WorkMessageQueue.swift`, `WorkMessageOutcome.swift`, `ParallelVM+Messages.swift` | Keep queue/Send now/cancel/Continue Accepted | A task/parallel composer references | Queue/refused/unknown/unsupported not drawn; Continue semantics unresolved |
| `RawEventsSheetView.swift`, `RawEventsPaneView.swift`, `TaskArtifactsView.swift`, `SummaryEditedFilesViews.swift` | Events simplification Proposed; Artifacts/Changes Accepted | A `screens-task.js`: `task/done` right-pane tabs | Separate Artifacts/Events loading/empty/error/page specimens absent; changes incomplete/not_captured/unmerged_unknown/provenance/non-authorship |
| `TaskDetailView.swift:443` overflow; `:274,431` inspector | Keep Cancel/copy resume/ID; remove inspector/Technical info Accepted | A task top bar, overflow missing | Exact cancel scope/earlier-turn survivors; enforcement truth moves elsewhere; no takeover entry |
| CallerApprovalController/Presentation, NeedsYou, MenuBarFeature | Inline task/question/approval Accepted | A `screens-needs-you.js`: `needs-you/waiting`, `needs-you/empty`; `screens-menu-bar.js`: `menu-bar/busy`, `menu-bar/empty`; task/approval | Exact-action relabel mandatory; stale/expired/shared-responder/refused/unknown/read-refresh |
| WorkflowRunnerView/list routes | Keep definition list/run Accepted; separate runs | A `screens-workflows.js`: `workflows/list`, `workflows/empty`, `workflows/run` | Loading/error, Task required/Goal optional validation, qualified override, refused/unknown launch |
| WorkflowView:275, WorkflowAgentEditor/NodeExecutionSettings/canvas/clipboard/undo | Keep roles/child/parallel/on-demand/conditions/limits/fallbacks/undo/redo/copy/paste Accepted | A/B `screens-workflow-editor.js`: `workflow-editor/node-selected`, `workflow-editor/orchestrator`; C provenance decision | Validation/conflict/missing child/unsupported fallback/unsaved edits; orchestrator non-removable/no connections |
| WorkflowView:235,390; WorkflowVM+AgentEdit:22/+Draft/+Generate | Keep Edit and Generate Accepted | B `screens-workflow-editor.js`: `workflow-editor/edit-with-agent` right pane (C later change flagged) | Generate entry/description/progress; proposal loading/failure/review/apply conflict preserving edits |
| WorkflowView:241; WorkflowVM:354,379 | Delete kept; Duplicate removed Accepted | No approved confirmation specimen | Confirmation says existing run snapshots remain; saved workflow Rename unshipped/backlog |
| WorkflowView:189; WorkflowVM+Control:24; recovery | Keep graph/parallel/pause/resume/cancel/recover Accepted | A `screens-workflow-run.js`: `workflow-run/graph-needs-you`, `workflow-run/parallel`, `workflow-run/recovery`, `workflow-run/on-demand`; C later change flagged | Stale checkpoint, root/session ownership, nested control/caller loss/unknown/refusal |
| WorkflowGoalView:61; WorkflowVM+Goal/+ActivityMessages | Proposed keep node/orchestrator messages/revise goal | No approved action specimens | Scope decision then revision/conflict/queued/refused/unknown states |
| WorkflowRunDiagnostics/context/retry | Proposed simplify details to approved run surfaces | Above run states | Owner decides retained accessible details; recovery truth must remain |
| ParallelView/ActivityViewport/+Messages | Keep lanes/composers/Cancel all; flat group row Accepted | A `screens-parallel-group.js`: `parallel-group/lanes` | Partial/unknown cancel scope; narrow/focus/visible-column history and residency; group start MCP-only |
| Resource repositories/UI | Keep observation Accepted; admin reduction Proposed | A `screens-resources.js`: `resources/slots` | Empty/error/over-limit/permission/disabled/unsupported; worktree/scratch Undecided |
| StatisticsView/projection/history worker | Keep overview/range Accepted | A `screens-statistics.js`: `statistics/overview` | Empty/error/incomplete/null/unsupported; all-time beyond retention unavailable, complete-generation derived metrics |
| SettingsFeature general/harnesses/MCP permissions | Keep appearance/behavior/runtime/status/registration/qualification/global allowlist Accepted | A `screens-settings.js`: `settings/general`, `settings/harnesses`, `settings/mcp-approvals` | Human-only narrow future-session config, restrictions/refusal/unknown; recovery actions Undecided |
| Managed runtime/startup views | Keep install/update/loading/unavailable Accepted | A `screens-app-states.js`: `app-states/setup`, `app-states/loading`, `app-states/engine-error` | “Start engine”, ECONNREFUSED and engine.sock are mock-only, not ctl lifecycle; redesign honest errors/retry |
| Harflow App/AppCoordinator/lifecycle | Keep native notifications/URLs/single instance/window/menu Accepted | A menu-bar states; native adaptation missing | Native chrome, permission/click focus, early/visible-window URL behavior, setup failures |
| HfUI/appearance | Keep System/Light/Dark footer/rail cycle Accepted | A `components.js`, `v2/styles/`; later foundations/brand content needs cited provenance | Native keyboard/AX/Reduce Motion/contrast/narrow/large text; dark mid-grey #2b2b2d; blossom template menu icon/violet squircle app icon |

## Full unresolved S03 disposition list

Do not promote any row to Accepted by delivering M01:

| Status | Items | Proposed disposition for owner |
| --- | --- | --- |
| Proposed keep | Effort, turn limit, caller approvals; enforcement preview; workflow node/orchestrator messages and revise goal | Ratify separately; qualify per capability and design outcomes |
| Proposed simplify | Raw events→Events pane; run diagnostic details; slot administration→ctl/MCP only; usage counts→per-repository remembered choices | Ratify with recovery truth retained; no agentUsage.v1 count transfer |
| Proposed remove | Builder “Always allow Harflow tools” shortcut (`TaskDetailView.swift:176` exists); unshipped starring, sidebar context/delete, task/workflow rename, standalone reorder, setup/teardown, readiness, legacy recovery proposals, header appearance | Remove shortcut, route ordinary approvals inline; keep unshipped items backlog, no issue mutations |
| Undecided | Store inspect/backup/reset beyond status | R01 policy then affected settings design; no new destructive controls |
| Undecided | Worktree/scratch client observation | Decide before M10; engine support/cleanup remains required regardless |
| Proposed exact surface | 47/eight MCP partition; historical69/77 ctl partition | See M01-contracts; accepted backend deferral policy does not ratify exact schema/path lists |

Already accepted client removals stay removed: search/sidebar harness filter, old task-level tabs, Council, inspector/Technical info, Duplicate workflow. This removes presentation, not public APIs, history or execution/authority guarantees. Terminal takeover/attach, webhook subscriptions, limit-hit projections and other accepted D12 deferrals are not silently restored.

## Bounded M01-Gxx briefs — proposed, not commissioned

Each later brief must inventory its public data/authority, create only the named missing Design states, cover loading/empty/populated/error/interaction where applicable, obtain explicit owner approval and return immutable commit/path/state/light-dark references plus native keyboard/focus/AX/Reduce Motion/narrow behavior. No mock can grant an API. Required states remain blocking until that receipt exists.

| Brief | Bounded scope / dependent slice |
| --- | --- |
| M01-G01 | Native shell/chrome/sidebar/footer/window minimum, keyboard/focus/accessibility/Reduce Motion; M04–M12 |
| M01-G02 | Capability/qualification/enforcement advanced composer and validation/refused/unknown start; scope decision first; M04 |
| M01-G03 | Task lifecycle, overflow/exact cancel scope, bounded history/retention/reconnect/unavailable; M05 |
| M01-G04 | Changes/Artifacts/Events loading/empty/error/capture/partial/unknown/provenance/non-authorship; M05 |
| M01-G05 | Queue/Send now/cancel/unsupported/refused/unknown, task and lane composers; M06 |
| M01-G06 | Exact-action approvals/questions/checkpoints in transcript/Needs you/menu bar; stale/expiry/shared/current owner/read refresh; M07 |
| M01-G07 | Editor validation/conflicts/missing references/fallbacks/unsaved draft/Delete confirmation; M08 |
| M01-G08 | Generate/Edit with agent entry/progress/failure/proposal review/apply conflicts; B right-pane preserved; M08 |
| M01-G09 | Nested/parallel run/recovery/control scope and unknown/refusal; node/orchestrator messages/goal only after decision; M09 |
| M01-G10 | Resource slots empty/error/disabled/unsupported/permission/over-limit; worktree/scratch only after decision; M10 |
| M01-G11 | Statistics empty/error/incomplete/null/unsupported metric/retention; M10 |
| M01-G12 | Honest managed ctl runtime setup/update/unavailable, registration and narrow allowlist; recovery only after decision; M03/M11 |
| M01-G13 | Native menu bar/notifications/deep links/single-instance lifecycle/window focus; M11 |

The current approved browser specimen is the visual starting point; existing native behavior supplies evidence for interaction safety. Neither establishes approval for an invented native adaptation. No new design references or approvals are recorded here.
