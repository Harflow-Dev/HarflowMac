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
