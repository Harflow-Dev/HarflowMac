# Harflow for Mac

Harflow is a native macOS interface for agent tasks and workflow nodes. Installed command-line tools are called harnesses; the AI workers they run are agents.

Version 0.0.2 is under development. On Apple Silicon with macOS 26, the app prepares its exact paired HarflowMCP runtime and reuses a qualified installation without network access. First preparation requires the paired release on PyPI. Harness MCP registrations remain explicit actions in Settings → Harnesses. The app does not adopt legacy or external runtimes.

Workflow runs show selected node activity in the Graph sidebar, with attempt selection and on-demand call history. Deselect a node to return to the retained run plan. The bottom summary expands above the graph; Parallel shows all current workflow task columns.

Compatible engines expose capture ownership, live-input availability and background idle-cutoff diagnostics in the existing inspector notices. Lost-capture tasks can show source-labelled backend transcript activity; it is display only and does not establish completion or restore messaging. The app retains its explicitly paired engine version; older engines keep their existing captured activity.

See [managed runtime](docs/managed-runtime.md) for acquisition, storage, retry, and current distribution limits.

See [development](docs/development.md), [architecture](docs/architecture.md), [profiling](docs/monitor-performance.md), and [signing preparation](docs/ci-signing.md).

Runtime identity and compatibility follow [HarflowMCP’s public contracts](https://github.com/Harflow-Dev/HarflowMCP/blob/main/docs/contracts.md).

See the [Changelog](CHANGELOG.md) for change history.

Licensed under Apache 2.0. Copyright Nayanda Haberty.

Release validation and distribution prerequisites are documented in [Releasing](docs/releasing.md).
