# Harflow for Mac

Harflow is a native macOS interface for harness sessions, agent tasks, and workflow nodes. Installed command-line tools are harnesses; the AI workers they run are agents.

Version 0.0.9 pairs with HarflowMCP 0.0.11. On Apple Silicon with macOS 26, the app checks for its exact paired HarflowMCP runtime without downloading software. If installation or an update is needed, choose Install required components or Update required components in the sidebar or Settings → General. While setup is required, the sidebar shows the setup card and retains its appearance and settings footer, and the detail pane shows the matching setup, progress or failure state. The current source pairs with engine 0.0.11; explicit installation requires that exact release on PyPI. A qualified installation is reused without network access. Harness MCP registrations remain explicit actions in Settings → Harnesses. The app does not adopt legacy or external runtimes.

Task activity uses bounded public event pages. The task transcript includes a separately read Original request disclosure and inline history health; Events shows normalized records, qualified observed tool totals and separately labelled recovered transcript material. Missing capture or unsupported payloads leave totals unavailable. Stored requests distinguish full text, previews, partial text and integrity failures. Load current activity explicitly replaces a full or changed-source reading window. These reads require `task-event-page.v1` and `task-prompt.v1`; the paired 0.0.11 runtime provides both capabilities.

Resource slots in Overview shows capacity, holders and ordered waiters from a compatible engine, with links to known owning tasks and workflow runs. Task details show reported phase leases and actual blockers. Initial loading uses shimmer, with static placeholders under Reduce Motion; refresh failures retain and label the last successful view. This read-only screen requires `phase-slots.v1` and never enables slots or changes cleanup policy.

Workflow runs sort and enter Today or Earlier by their creation time, so node progress does not move them around. Explicit resume ordering awaits the engine’s caller-resume timestamp contract.

New task opens an inline composer with repository, harness, model and access choices. The + button opens advanced options in a bounded popover. Choices remain in memory for this window, separately by repository; unavailable choices stay visible for correction. Qualification status remains visible when options are closed. A submission with an unknown outcome stays locked while you review recent tasks, so revisiting the composer or pressing Command-N cannot replay it. A definitive settings refusal permits correction and a fresh submission.

The sidebar scrolls navigation, Running and Recent work together in one body, with the brand header and appearance/settings footer fixed. Collapse it to an icon rail without discarding the current draft or selected task. A qualified runtime whose first task listing fails shows a listing retry rather than an installation request.

Needs you opens from the sidebar. It lists every request Harflow can answer now, across tasks and workflows (including nested nodes and child workflows), whoever started the run: questions, recovery checkpoints at an attempt limit, usage-limit choices and approvals. Open a request to read it in full with its path, who started it and who owns it, then answer in place. Engines advertising shared workflow responders let the original caller and Harflow answer the same question or recovery checkpoint. The first accepted answer wins without changing ownership. If the caller answers first, Harflow closes the form, shows the winning answer and retains your unsent draft. Answer history identifies the responder. Older engines retain their existing caller ownership and handover rules; unknown or unavailable responders never grant control. The sidebar count is a lower bound ("3+") while some runs could not be read yet. Harflow notifies you when a request becomes answerable (Settings → General → Notify when a request needs you); requests already pending at launch do not notify, and an approval notification names only the tool, never the command. The menu bar popover shows the first three with Show all. Recovery answers require an engine with `workflow-attention-checkpoints.v1`; they are bound to the displayed checkpoint and refused if it changes. The paired engine 0.0.11 provides this capability. Needs you needs a compatible workflow-status projection (`interaction_state`, present in engine 0.0.11); without it only task approvals appear, with a notice.

Statistics opens from the sidebar. Its graph fits the available window width; long rankings scroll vertically. Compatible engines provide retained finished-history time and token accounting for local 7, 30, or 90-day ranges, with repository, harness and requested-model filters. Totals wait for complete bounded history pages; missing accounting stays unavailable and retention is disclosed. This version pairs with engine 0.0.11, which provides `statistics-page.v1`; older engines show an explicit unsupported state.

Workflow runs show selected node activity in the Graph sidebar, with attempt selection and on-demand call history. Activity fits the inspector width and scrolls vertically; nodes with several conversations offer a conversation selector. The standalone Orchestrator card highlights confirmed running decision tasks; selecting it opens the current or latest decision activity, with earlier decisions available in the inspector. Consultant calls retain their details alongside associated activity. Deselect a node to return to the retained run plan. The bottom summary expands above the graph; Parallel shows all current workflow task columns.

Task details can show a quiet restart-continuity note from qualified engine supervision evidence, with diagnostic history in Technical info. The paired engine 0.0.11 supplies qualified parent-observer evidence. See [task supervision](docs/architecture.md#task-supervision-and-continuity).

Task approvals appear inline in the task transcript; workflow approvals remain in the run sidebar. Pending requests show the complete action and stay expanded. Answered requests collapse to an expandable settled row. Compatible engines let Harflow answer caller-owned requests; older engines retain read-only guidance for those requests. Decision acceptance, delivery and observed execution are shown separately.

Parallel panels keep a 630-point minimum width and scroll horizontally when they cannot fit. An open single-conversation group switches to Parallel as independent conversations join, retaining the original activity and reading position. Standalone and workflow Parallel views retain their horizontal pixel position when conversations arrive, resume or reorder, including after switching away and back. Removal and resizing clamp only to the available scroll range.

Loading placeholders hand off to resolved content with one short opacity crossfade per retained selection. Reduce Motion switches immediately; live updates and pagination keep content visible.

Streaming replies retain completed Markdown blocks while preparing the changing tail in the background. Activity feeds use the same prepared layout for measurement and display, keep native row hosts tied to displayed rows, and retain text selection while avoiding row refreshes for unchanged content. Native workflow subagent activity follows the live end through content and viewport changes; scrolling up pauses following until the reader returns near the bottom.

Compatible engines expose capture ownership, live-input availability and background idle-cutoff diagnostics in the existing inspector notices. Lost-capture tasks can show source-labelled harness transcript activity; it is display only and does not establish completion or restore messaging. The app retains its explicitly paired engine version; older engines keep their existing captured activity.

New session and workflow launch show the engine’s required harness feature checks before starting. Opening a form reads cached evidence; Check harness explicitly runs the checks, with cancellation and retry. Settings → Harnesses shows qualification separately from MCP registration. Evidence must match the selected runtime and harness binary. The paired engine 0.0.11 supplies `backend-qualification.v1`; new launches require matching successful qualification evidence.

Harness and model menus share lifetime usage ranking from successful app submissions. Workflow node menus prefer a supported orchestrator agent and model while preserving saved selections.

Retained workflow read failures appear as a counted entry above the sidebar appearance and Settings controls. Open it to read each failure and retry; the entry disappears when all sources recover. The top incident notification remains dismissible.

The title bar shows Harflow's engine connection status. Choose Light, Dark, or System from the sidebar footer icons to set the appearance across Harflow. System follows this Mac's appearance setting.

After an install or update, its success notice appears above the sidebar controls and in the menu bar popover. Dismissing it hides it in both places. Quitting also ends the notice; reopening with an up-to-date engine does not show it again. Runtime readiness and Settings setup controls remain available.

Store incompatibility retains the qualified runtime and shows a sidebar attention entry. Settings → General offers read-only inspection and explicit backup and reset, bound to the inspected operation. Interrupted recovery requires a fresh inspection and confirmation. The engine-returned backup receipt remains available for Finder reveal after recovery. See the [managed runtime guide](docs/managed-runtime.md#store-readiness-and-recovery).

See [managed runtime](docs/managed-runtime.md) for acquisition, storage, retry, and current distribution limits.

See [development](docs/development.md), [architecture](docs/architecture.md), [profiling](docs/monitor-performance.md), and [signing preparation](docs/ci-signing.md).

See [product terminology](docs/terminology.md) for user-facing terms and compatibility names.

Runtime identity and compatibility follow [HarflowMCP’s public contracts](https://github.com/Harflow-Dev/HarflowMCP/blob/main/docs/contracts.md).

See the [Changelog](CHANGELOG.md) for change history.

Licensed under Apache 2.0. Copyright Nayanda Haberty.

Release validation and distribution prerequisites are documented in [Releasing](docs/releasing.md).

Task Activity, each Parallel panel and each selected node’s right-hand Activity have message boxes that queue by default, with secondary Send now and visible engine refusal reasons. Selected nodes keep the header at the top and message box at the bottom even before activity starts. The workflow canvas has no global message box; select Orchestrator to message it in Activity. See [interaction surfaces](docs/interaction-surfaces.md) for ownership, recovery and compatibility behavior.
