# PbUtilities

The Monitor's lowest foundation package: generic Combine/SwiftUI helpers with no app-specific types.
See `../../AGENTS.md` for the architecture rules these helpers serve.

## What's here

- `@Subjected` — a thread-safe `CurrentValueSubject` property wrapper (a `Sendable` alternative to
  `@Published`), plus `Publisher.assign(to:)`/`uniqueAssign(to:)` onto it.
- `Publisher.weakAssign(to:on:)` / `tapWeakAssign(to:on:)` — weak-reference-safe Combine sinks.
- `View.eraseToAnyView()`.
- `ArrayBuilder<Element>` — the result builder behind `AlertContent`'s actions list (PbCommon).
- `PbModuleDelegate` + `PbModule` + `ApplicationModules` — the three-phase module lifecycle
  (`modulesWillInitialize` → `initializeModule` → `modulesDidInitialize`, run in registration order)
  that Phase 5's `AppCoordinator`/`AppModulesRegistry` wires up.
- A public `AnyView` dummy (`Dummyable` ships none for AppKit/macOS).
- **`PbTestUtilities`** (a separate library product): `waitUntil(timeout:condition:)` (50 ms
  polling) and `TestError`.

## Build & test

```bash
cd macos/PbFoundation/PbUtilities
swift build
swift test
```

## Dependencies

Remote only, pinned exact: `SwiftEnvironment` 4.1.8, `Dummyable` 1.1.6, `Mockable` 0.6.2. No local
dependencies — this is the foundation everything else builds on.
