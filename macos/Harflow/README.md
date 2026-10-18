# Harflow

The root executable package for the Harflow macOS app. Owns the app shell only: `App.swift`
(`HarflowApp`, `AppDelegate`), `AppCoordinator` (the root coordinator every feature
coordinator eventually bubbles an unhandled `handle(path:)` to), and `AppModulesRegistry` (the
ordered list of every application module). Every screen lives in a `HfFeatures/*` package; this
target only wires them together and owns the process lifecycle. See `AGENTS.md` for the rules this
package follows and `../AGENTS.md` for the shared rulebook.

## Build, test & package

```bash
cd macos/Harflow
swift build
HARFLOW_NATIVE_BENCHMARK=1 python3 ../../scripts/test-swift-package.py --package . --mode aggregate
cd ../..
macos/build-app.sh   # builds macos/build/Harflow.app (ad-hoc signed)
```
