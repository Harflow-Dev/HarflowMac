# PolybridgeMonitor

The root executable package for the Polybridge Monitor macOS app. Owns the app shell only: `App.swift`
(`PolybridgeMonitorApp`, `AppDelegate`), `AppCoordinator` (the root coordinator every feature
coordinator eventually bubbles an unhandled `handle(path:)` to), and `AppModulesRegistry` (the
ordered list of every application module). Every screen lives in a `PbFeatures/*` package; this
target only wires them together and owns the process lifecycle. See `AGENTS.md` for the rules this
package follows and `../AGENTS.md` for the shared rulebook.

## Build, test & package

```bash
cd macos/PolybridgeMonitor
swift build
swift test
cd ../..
macos/build-app.sh   # builds macos/build/Polybridge Monitor.app (ad-hoc signed)
```
