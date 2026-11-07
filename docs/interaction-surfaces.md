# Work visibility and interaction

Harflow displays work independently of whether the app, MCP, CLI or another agent started it.
The Activity header uses one supplemental stack for notices and continuity: 16-point symbol
columns, 8-point text gaps and 12-point row gaps, with the same outer inset as metadata.

The implementation reference is HarflowDesign commit `7150aa7`,
`features/work-interaction.html`, states Task,
Workflow run, Orchestrator Activity, Node task and Parallel; ready, queued, refusal, attempt limit, child,
unsupported, loading and long text in Light/Dark. Composer placement follows the owner’s explicit correction on 2026-10-29: no global run composer, Orchestrator and node Activity composers on the right, and one composer per Parallel panel. Other visual details remain exploratory; browser/native pixel fidelity is separate.

| Surface | Presentation and public engine route |
| --- | --- |
| Task screen | Always offers queued Send and secondary Send now, including tasks without live input. `send --monitor` routes workflow-owned tasks through their run. Taken-over sessions explain why messaging is unavailable. |
| Queued messages | Queued bubbles appear at the end of the task Activity feed and of each Activity surface, with Cancel while queued. `cancel-message` or `workflow-cancel-message --monitor` withdraws the exact message ID. |
| Workflow run | The canvas has no global composer. Select Orchestrator to open its right-hand Activity and composer; messages route through that activity’s exact task. |
| Workflow create/edit | No workflow-window composer (#43). Builder tasks start from Generate and Edit with agent. An embedded builder task keeps its own sole composer. |
| Selected node Activity | Every node’s right-hand Activity includes a composer. Task activities use their current task; native and fallback surfaces use `workflow-send --monitor --task-id`, child-workflow Activity addresses that child’s orchestrator. An unstarted or unavailable target shows a disabled composer with its specific reason. Empty activity keeps the header at the top, the placeholder centred in the remaining space and the composer at the bottom, including when an attempt picker is present. |
| Parallel mode | Each visible conversation panel owns a composer for its current task, including the selected node Activity’s shared panel. There is no global run composer. |
| Recovery/questions/attempt limits | Recovery details remain visible for caller-owned and child runs. Extra attempts, Resume/Recover and optional-review consent use fresh `monitor_controls`; unavailable controls retain a reason. Children offer Open root rather than applying a child's answer to its root. |
| Pause/goal revision | Relevant controls remain discoverable. Engine eligibility determines enablement and every mutation passes `--monitor`. Old engines retain conservative owner eligibility. |
| Resource slots | Read-only capacity, holders and ordered waiters from public engine reads. Qualified Open task and Open workflow run actions use existing detail routes. Back to resource slots appears only for an owner opened there; unrelated navigation clears that return route. Task phase context can open the overview. Unknown metadata never invents an owner route or zero usage. |
| Sidebar | Builder, native control and transport tasks are discoverable under their workflow, with ordinary task fallback when no workflow is known. Conversation grouping preserves parent relationships. |
| Approval cards | Existing engine feature, ownership and current-request validation remain authoritative. A visible request never grants permission to answer it. |
| Terminal/takeover | Managed and native-subagent restrictions remain in force. A disabled takeover action explains the owning-workflow route. |
| Menu bar | Existing task monitoring remains independent of launch origin. Opening a task routes to its conversation; workflow controls belong in the main window. |

Eligibility is advisory and refreshed with status. The engine revalidates ownership, pending
approval, settling, checkpoint identity and supported operation when the user acts. A stale
allowed flag cannot grant authority. Immediate delivery never bypasses those checks; refusal
keeps queued text intact. The app neither reads nor mutates engine records to implement actions.

Non-question workflow recovery requires `workflow-attention-checkpoints.v1` and an identifier from the displayed status. The engine refuses a changed checkpoint; Harflow refreshes the status and preserves the entered instructions without replaying them. Engines without this capability cannot perform these actions. Questions continue to use their decision identifier.

## macOS notifications

On engines advertising `interaction-events.v1`, Harflow reads a bounded durable event
feed and posts an individual Notification Center banner for each pending question,
approval, recovery request and accepted answer, plus each observed completed or failed
task. Answer banners name the responder and include a bounded winning-answer excerpt.
Clicking a workflow banner opens its root run; a standalone-task banner opens the task.
Native notification permission and the existing Needs you / task-finish preferences
still apply. Foreground delivery uses banners and sound.

App-owned delivery IDs are persisted per selected engine state root, independently of
engine storage. Initial historical episodes are baselined, retained newer episodes
survive app restart, and completed scan cycles safely replay stable IDs without duplicate
banners. Deduplication retains a rolling 30-day window. The feed explicitly reports
source/retention gaps; removed episodes cannot be recovered. A failed notification post
is retried on a later scan. Engines lacking the capability retain the existing Needs you
and root-task listing notifications; those older paths cannot discover between-poll
requests or task transitions. No provider-message subscription is created.

Shared answering follows owner-approved HarflowDesign commit `690ec495b148293172ac93272b81e3d68c2f8e7d` (2026-11-02),
`docs/shared-answering.md`, `features/work-interaction.html` and `features/needs-you.html`,
Shared answer, Caller answered first and Harflow answered first states in Light and Dark.
The additive engine capability is
`workflow-shared-interactions.v1`; `interaction_state.responders` grants explicit response
channels while `interaction_owner` retains ownership. A live caller no longer disables an
explicit Monitor responder. Existing checkpoint, settling, input and command checks still apply.
Absent responders preserve legacy behavior.

The recovery and Needs you forms explain that the original caller can also answer. A structured
`interaction_already_answered` receipt closes the stale form and shows **Already answered by the
caller**, the winning answer, timestamp and **Your saved draft**. An accepted Monitor response
shows **Answered in Harflow**. Workflow answer history uses engine-persisted `interaction_history`;
missing historical attribution is never invented. Approval refusals retain their engine-provided
winner, and settled approval details show their actual responder separately from delivery.
