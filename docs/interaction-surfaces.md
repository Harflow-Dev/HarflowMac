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
| Task screen | Offers queued Send, including tasks without live input. Send now appears for running tasks when the current engine reports `messaging.v1`. Settled standalone tasks without workflow ownership retain Cancel on queued messages, which wait for an explicit eligible Continue in a new session. `send --monitor` routes workflow-owned tasks through their run. Taken-over sessions explain why messaging is unavailable. |
| Queued messages | Queued bubbles appear at the end of the task Activity feed and of each Activity surface, with Cancel while queued. `cancel-message` or `workflow-cancel-message --monitor` withdraws the exact message ID. |
| Workflow run | The canvas has no global composer. Select Orchestrator on a regular root run to open its right-hand conversation. Open, Reply, starting a new conversation and Dismiss follow current engine eligibility for the exact root and episode. A held conversation shows Needs you. A real open run question keeps the composer locked and links to Needs you. |
| Workflow create/edit | No workflow-window composer (#43). Builder tasks start from Generate and Edit with agent. An embedded builder task keeps its own sole composer. |
| Selected node Activity | Every node’s right-hand Activity includes a composer. Task activities use their current task; native and fallback surfaces use `workflow-send --monitor --task-id`, child-workflow Activity addresses that child’s orchestrator. An unstarted or unavailable target shows a disabled composer with its specific reason. Empty activity keeps the header at the top, the placeholder centred in the remaining space and the composer at the bottom, including when an attempt picker is present. |
| Parallel mode | Each visible conversation panel owns a composer for its current task, including the selected node Activity’s shared panel. A Parallel lane's composer is one row that queues only, labelled for its harness ("Message Codex", send "Send to Codex"), enabled on a settled lane and locked on a taken-over one; the Graph inspector's column keeps Send now. A lane's queued bubbles and its outcome line (after the bubbles) sit in the feed tail. There is no global run composer. |
| Recovery/questions/attempt limits | Recovery details remain visible for caller-owned and child runs. Extra attempts, Resume/Recover and optional-review consent use fresh `monitor_controls`; unavailable controls retain a reason. Children offer Open root rather than applying a child's answer to its root. In Graph view a run that needs recovery shows Recovery options as the 360-point right-hand pane (HarflowDesign `workflow-run/recovery`): a fixed head with the run's status badge, then the failure sentence (the engine's question), Additional instructions, Extra attempts, the stacked Continue with one more retry, Proceed without optional reviewer and Resume or Recover actions, the goal block, and the run sidebar's other sections (approvals, child links, original request, plan). Selecting a node shows that node's pane instead; the status badge in the header returns to the recovery pane and focuses the instructions. In Parallel view the same form stays a floating, dismissible panel over the lanes (the design gives Parallel no right pane). |
| Pause/goal revision | Relevant controls remain discoverable. Engine eligibility determines enablement and every mutation passes `--monitor`. Old engines retain conservative owner eligibility. |
| Resource slots | Read-only capacity, holders and ordered waiters from public engine reads. Qualified Open task and Open workflow run actions use existing detail routes. Back to resource slots appears only for an owner opened there; unrelated navigation clears that return route. Task phase context can open the overview. Unknown metadata never invents an owner route or zero usage. |
| Sidebar | Builder, native control and transport tasks are discoverable under their workflow, with ordinary task fallback when no workflow is known. Conversation grouping preserves parent relationships. |
| Approval cards | Existing engine feature, ownership and current-request validation remain authoritative. A visible request never grants permission to answer it. |
| Terminal/takeover | Managed and native-subagent restrictions remain in force. A disabled takeover action explains the owning-workflow route. A Parallel lane has no takeover button (its Lane actions menu holds Open task only); Take over stays on the task screen and the Graph inspector. |
| Menu bar | Existing task monitoring remains independent of launch origin. Opening a task routes to its conversation; workflow controls belong in the main window. While the runtime is not ready the popover shows a setup, preparing or failed block with Open Harflow instead of its sections, and "+" is disabled until work is available. A failed refresh of listed work adds a note with Retry above the kept rows. |

Eligibility is advisory and refreshed with status. The engine revalidates ownership, pending
approval, settling, checkpoint identity and supported operation when the user acts. A stale
allowed flag cannot grant authority. Immediate delivery never bypasses those checks; refusal
keeps queued text intact. The app neither reads nor mutates engine records to implement actions.

Root orchestrator conversations use the paired `workflow-steering-read.v1`
and `workflow-steering-orchestrator.v1` capabilities via public monitor
operations. The composer keeps the draft while an invocation is unresolved.
Only a confirmed admission for that exact request can clear the corresponding
draft. Dismiss does not replay or submit a draft. When Dismiss leaves Resume
unavailable, the run shows the engine's reason when supplied. Existing exact
queued-message Cancel remains available where the engine offers it.

Approval requests from issued workers in the selected root run expand in the
Orchestrator conversation. Each request names its issuer and carries its own
Approve once and Reject controls. The conversation, requests and Dismiss
share the same scrolling body, with the heading and reply composer fixed.
Approval eligibility and steering reply eligibility are checked separately.
The Run pane retains the wider workflow-tree approval list.

In the selected task inspector, approval details and actions expand together
inside the activity scroll area. In a retained Orchestrator conversation,
the task activity and its exact task requests precede steering history and
the issued workers' run-scoped requests. Pending replies appear as outgoing
bubbles at the end of that same content with their available Cancel action.
The fixed composer edge fades while there is content below the viewport
and stays clear at the end or over an action.

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
is retried on a later scan. Engines lacking the capability post no notifications: the
earlier Needs you and root-task listing notifiers were removed (owner decision 2026-11-23).
The task-finished setting still gates task banners from this feed. No provider-message subscription is created.

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
