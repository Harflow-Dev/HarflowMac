# MainWindowFeature

The main window's whole split view for Polybridge Monitor — Sidebar, New Session, Parallel,
TaskDetail and Interactive, plus the `NavigationSplitView` itself (`MainWindowNavigationView`) — built
on the `Coordinator → NavigationView → View → VM → UseCase → ViewRepository` architecture.
See `AGENTS.md` for the rules this package follows and `../../AGENTS.md` for the shared rulebook.

## Build & test

```bash
cd macos/PbFeatures/MainWindowFeature
swift build
swift test
```


The task Summary includes a separate Registered artifacts section for standalone tasks. Each
conversation member loads its own bounded metadata page only when requested, with explicit paging
and refresh. Expand an artifact to read its full verbatim note, source task, registrar, path and
availability observation. The Monitor never reads artifact contents or treats registration as task
success or an edited-file record. Unsupported older CLIs report metadata unavailable; legacy tasks
with no manifest show no registered artifacts after a successful read. Workflow artifacts are not
supported.
