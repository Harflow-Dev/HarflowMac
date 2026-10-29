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
| Task Activity/Summary/Prompt | Always offers queued Send and secondary Send now, including tasks without live input. `send --monitor` routes workflow-owned tasks through their run. Taken-over sessions explain why messaging is unavailable. |
| Queued messages | Queued bubbles appear at the end of the Task Activity tab and of each Activity surface, with Cancel while queued. The Summary and Prompt tabs keep the composer but not the bubbles. `cancel-message` or `workflow-cancel-message --monitor` withdraws the exact message ID. |
| Workflow run | The canvas has no global composer. Select Orchestrator to open its right-hand Activity and composer; messages route through that activity’s exact task. |
| Workflow create/edit | No workflow-window composer (#43). Builder tasks start from Generate and Edit with agent. An embedded builder task keeps its own sole composer. |
| Selected node Activity | Every node’s right-hand Activity includes a composer. Task activities use their current task; native and fallback surfaces use `workflow-send --monitor --task-id`, child-workflow Activity addresses that child’s orchestrator. An unstarted or unavailable target shows a disabled composer with its specific reason. |
| Parallel mode | Each visible conversation panel owns a composer for its current task, including the selected node Activity’s shared panel. There is no global run composer. |
| Recovery/questions/attempt limits | Recovery details remain visible for caller-owned and child runs. Extra attempts, Resume/Recover and optional-review consent use fresh `monitor_controls`; unavailable controls retain a reason. Children offer Open root rather than applying a child's answer to its root. |
| Pause/goal revision | Relevant controls remain discoverable. Engine eligibility determines enablement and every mutation passes `--monitor`. Old engines retain conservative owner eligibility. |
| Sidebar | Builder, native control and transport tasks are discoverable under their workflow, with ordinary task fallback when no workflow is known. Conversation grouping preserves parent relationships. |
| Approval cards | Existing engine feature, ownership and current-request validation remain authoritative. A visible request never grants permission to answer it. |
| Terminal/takeover | Managed and native-subagent restrictions remain in force. A disabled takeover action explains the owning-workflow route. |
| Menu bar | Existing task monitoring remains independent of launch origin. Opening a task routes to its conversation; workflow controls belong in the main window. |

Eligibility is advisory and refreshed with status. The engine revalidates ownership, pending
approval, settling, checkpoint identity and supported operation when the user acts. A stale
allowed flag cannot grant authority. Immediate delivery never bypasses those checks; refusal
keeps queued text intact. The app neither reads nor mutates engine records to implement actions.
