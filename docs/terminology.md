# Product terminology

This glossary aligns native application copy with HarflowDesign's terminology guide. Product copy
uses the meanings below while source identifiers and public wire fields retain their compatibility
names.

| Term | Meaning and usage |
| --- | --- |
| Harness | Installed execution tool, such as Claude Code, Codex CLI, opencode, Mistral Vibe, or Antigravity. Use for tool selectors, filters, and tool status. |
| Agent | Autonomous AI participant doing work. A harness runs an agent. Retain for orchestrators, workers, generated roles, and counts of participants. |
| Model | A model selected inside a harness. Keep distinct from the harness and agent role. |
| Orchestrator | Agent coordinating a workflow and choosing its next actions. |
| Worker | Agent assigned a task or node. Planning, Implementation, Review, and Test describe roles rather than harnesses. |
| Workflow | Saved definition of nodes and transitions. |
| Node | Unit in a workflow graph, including branching, parallel execution, and nested workflows. Use for graph units and their accessibility labels. Use “step” for ordinary procedural instructions. |
| Workflow run | One execution of a workflow. Prefer this when “run” could be confused with a task. |
| Task | One assigned unit of work with its own identity and lifecycle. |
| Session | Harness conversation or context that can resume across task executions. Show the harness separately. |
| Execution mode | Launch mechanism, such as Headless or Orchestrator subagent. Keep separate from the Harness selector. |
| Runtime | Packaged Python engine and dependencies, distinct from external harnesses. |
| Access level | Requested read, write, or publish scope. Describe enforced permissions separately. |
| Activity | Event stream shown to users. Event counts are activity items, not workflow nodes. |
| Harflow | Application and product name. Historical source paths may retain older names where needed for accurate provenance. |

## Compatibility mapping

These public names remain unchanged for wire v1 and CLI compatibility. The user-facing copy uses the
corresponding product term where the context describes that concept.

| Compatibility name | User-facing meaning |
| --- | --- |
| `backend` | Harness |
| `model` | Model |
| `freedom` | Access level |
| `agent` | Agent participant configuration; not a synonym for Harness |
| `fallbacks` | Fallback harnesses |
| `orchestrator` | Orchestrator agent |
| `session_mode` | Session choice, including `agent_decides` |
| `execution_mode` | Execution mode |
| `node_id` | Workflow node identifier |
| `interaction_owner` | Interaction owner |
| `responder: "monitor"` | Harflow UI responder |
| `--monitor` | Existing CLI option for the Harflow interaction channel |

Internal Backend, Monitor, and Agent type names and adapter symbols remain as source compatibility
identifiers. Public keys, flags, accepted values, capabilities, and wire responder values are not
renamed by copy changes. “Agent decides,” agent-registered artifacts, and worker/orchestrator roles
retain their participant meaning.
