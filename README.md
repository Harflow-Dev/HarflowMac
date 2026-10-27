# Harflow for Mac

Harflow is a native macOS interface for harness sessions, agent tasks, and workflow nodes. Installed command-line tools are harnesses; the AI workers they run are agents.

Version 0.0.4 is under development. On Apple Silicon with macOS 26, the app checks for its exact paired HarflowMCP runtime without downloading software. If installation or an update is needed, choose Install required components or Update required components in the sidebar or Settings → General. While setup is required, the sidebar shows the setup card and retains its appearance and settings footer, and the detail pane displays the Harflow emblem. The current source pairs with engine 0.0.3; explicit installation requires that exact release on PyPI. A qualified installation is reused without network access. Harness MCP registrations remain explicit actions in Settings → Harnesses. The app does not adopt legacy or external runtimes.

With no item selected, the start screen offers New session and saved workflow launch shortcuts. It shows local-time activity summaries only when the engine provides complete history and ownership evidence. Compatible histories rank saved workflows by retained run count; older engines keep alphabetical shortcuts without counts. Run opens the saved definition and permission preview before execution.

Workflow runs show selected node activity in the Graph sidebar, with attempt selection and on-demand call history. Deselect a node to return to the retained run plan. The bottom summary expands above the graph; Parallel shows all current workflow task columns.

Task approvals appear in Activity, with pending hints in Summary and Prompt; workflow approvals remain in the run sidebar. Pending requests show the complete action and stay expanded. Answered requests collapse to an expandable settled row. Compatible engines let Harflow answer caller-owned requests; older engines retain read-only guidance for those requests. Decision acceptance, delivery and observed execution are shown separately.

Parallel panels keep a 630-point minimum width and scroll horizontally when they cannot fit. An open single-conversation group switches to Parallel as independent conversations join, retaining the original activity and reading position. Parallel and workflow activity follow new or resumed working conversations while the horizontal viewport is at its left edge; scrolling away keeps the current conversation in view. User scrolling cancels pending automatic movement.

Loading placeholders hand off to resolved content with one short opacity crossfade per retained selection. Reduce Motion switches immediately; live updates and pagination keep content visible.

Streaming replies retain completed Markdown blocks while preparing the changing tail in the background. Activity feeds use the same prepared layout for measurement and display.

Compatible engines expose capture ownership, live-input availability and background idle-cutoff diagnostics in the existing inspector notices. Lost-capture tasks can show source-labelled harness transcript activity; it is display only and does not establish completion or restore messaging. The app retains its explicitly paired engine version; older engines keep their existing captured activity.

Harness and model menus share lifetime usage ranking from successful app submissions. Workflow node menus prefer a supported orchestrator agent and model while preserving saved selections.

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
