# MonitorCore

The Monitor's bottom layer: dependency-free values and I/O — `polybridge-ctl`/`polybridge-setup`
JSON decoding, event tailing, lineage, git-status parsing, process/environment building, and the
child reaper. Foundation only, so its tests never need a window server.

Moved here unchanged from `PolybridgeMonitor/Sources/MonitorCore` as Phase 2 ("package skeleton") of
`.claude/plans/2026-09-25-monitor-architecture-plan-settled.md` — no code changed, only the package
boundary. It has no dependencies of its own, and any other package in this repo may import it.

## Build & test

```bash
cd macos/PbCore/MonitorCore
swift build
swift test
```

## Language mode

`swiftLanguageModes: [.v5]` — see `../../AGENTS.md` for why (its `assumeIsolated` process/tailing
internals do not compile under Swift 6's strict concurrency checking).
