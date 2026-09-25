# PbCommon

The Monitor's shared architecture contracts: `ViewModel`, `ViewEvent`, `AlertContent`, the
`Coordinator` family, `PathDestination`, and the per-feature factory protocols. See `../../AGENTS.md`
for the architecture rules they serve.

## What's here

- **`ViewModel`** (`@Mockable`) — `publishAlert`/`publishDialog`/`flushViewEvent` helpers over a
  `DidPublishViewEventPublisher`, plus the `View.publishViewEvent(from:to:)` bridge. Trimmed to the
  two presentation kinds the Monitor uses; no toast, input dialog, image picker, paywall, or Sign in
  with Apple (this app has none of those).
- **`ViewEvent`** — `alert(AlertContent)`, `dialog(AlertContent)`, `none`, plus the
  `@Environment(\.viewEvent)` entry PbUI's presentation modifier reads.
- **`AlertContent` / `AlertAction`** — title, optional description, and a builder-driven list of
  buttons (title, optional `ButtonRole`, action). Sized against the Monitor's four existing
  `confirmationDialog`s (`TaskDetailView.swift:84-97`, `ParallelView.swift:55-58,123-131`,
  `SettingsView.swift:102-109`) so Phase 4/5 can express each one exactly.
- **`Coordinator` / `ChildCoordinator` / `ParentCoordinator` / `ViewCoordinator`** and the
  `BranchCoordinator`/`ViewChildCoordinator` typealiases, plus `PathDestination` /
  `CompositeDestination` and `DummyCoordinator`/`DummyChildCoordinator`.
- **`MonitorDestination`** — the app's navigation destinations: `.task`, `.group`, `.interactive`,
  `.newSession`, `.openWindow`.
- **Feature factory protocols** (`MainWindowFeatureFactory`, `MenuBarFeatureFactory`,
  `SettingsFeatureFactory`), each a `@GlobalEntry` with a dummy default that never calls a
  `@MainActor` initialiser. Deliberately minimal — Phase 4/5 flesh out the real factories.
- **`PbCommonTestMock`** (a separate library product): `ViewChildCoordinatorMock`, the `@Mockable`
  restatement of the `ViewChildCoordinator` typealias (Mockable cannot generate a mock directly for
  a typealias).

## Build & test

```bash
cd macos/PbFoundation/PbCommon
swift build
swift test
```

## Dependencies

Local: `PbUtilities` (by path). Remote, pinned exact: `SwiftEnvironment` 4.1.8, `Dummyable` 1.1.6,
`Mockable` 0.6.2.
