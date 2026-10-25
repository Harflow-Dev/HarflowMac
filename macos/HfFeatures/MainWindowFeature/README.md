# MainWindowFeature

The main window's whole split view for Harflow — Sidebar, New Session, Parallel,
TaskDetail and Interactive, plus the `NavigationSplitView` itself (`MainWindowNavigationView`) — built
on the `Coordinator → NavigationView → View → VM → UseCase → ViewRepository` architecture.
See `AGENTS.md` for the rules this package follows and `../../AGENTS.md` for the shared rulebook.

## Build & test

```bash
cd macos/HfFeatures/MainWindowFeature
swift build
HARFLOW_NATIVE_SIDEBAR_BENCHMARK=1 python3 ../../../scripts/test-swift-package.py --package . --mode suites
```

Task approvals share a view-model-owned controller across Activity, Summary and Prompt. Activity presents complete pending actions at the feed tail; the other tabs provide an explicit reveal hint. Workflow approvals use the same cards in the run sidebar. Details, request currentness and engine capability remain independent approval gates, and a recorded decision does not imply execution success.


The task Summary includes a separate Registered artifacts section for standalone tasks. Each
conversation member loads its own bounded metadata page only when requested, with explicit paging
and refresh. Expand an artifact to read its full verbatim note, source task, registrar, path and
availability observation. The Monitor never reads artifact contents or treats registration as task
success or an edited-file record. Unsupported older CLIs report metadata unavailable; legacy tasks
with no manifest show no registered artifacts after a successful read. Workflow artifacts are not
supported.
