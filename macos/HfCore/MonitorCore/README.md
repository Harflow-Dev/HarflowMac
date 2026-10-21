# MonitorCore

Foundation-only values and I/O for Harflow wire decoding, event tailing, lineage, process execution, and environment construction. The package stays in Swift 5 language mode for its process/tailing concurrency internals; see [architecture rules](../../AGENTS.md).

## Compatibility

The canonical [wire specification](https://github.com/Harflow-Dev/HarflowMCP/blob/main/docs/contracts.md) is engine-owned. The consumer validates Harflow product identity, format, integer wire version 1, and stable product-version syntax before interpreting payloads. Live ctl/setup answers and compatibility probes require the selected major/minor release line; normalized events retain historical writer versions as provenance.

`RuntimeCompatibilityContext` carries the explicit lexical absolute state root. `VersionInfoClient` runs the selected `harflow-ctl version-info --json` directly through `ProcessRunning`, with a bounded strict document and no cache. Ctl commands and setup actions probe immediately before each operation with the same effective HOME/environment and working-directory policy. Setup probes its paired control executable, never PATH. Darwin/arm64 and the operation's advertised contract/capability are required. Lexical comparison preserves case and does not resolve symlinks; aliases that do not normalize equally safely refuse.

Tests vendor exact engine-owned fixtures under `Tests/MonitorCoreTests/Resources/ContractsV1`, including the engine manifest and its SHA256 digest. The package has no sibling-repository dependency or fixture download step. These envelopes do not establish storage ownership or runtime authenticity.

## Build and test

```sh
swift build --package-path macos/HfCore/MonitorCore
HARFLOW_NATIVE_BENCHMARK=1 python3 scripts/test-swift-package.py --package macos/HfCore/MonitorCore --mode aggregate
```

Complete malformed or incompatible event records make activity and summary reads explicitly unavailable. An incomplete trailing write is deferred until a newline completes it; unknown additive event kinds remain readable.

## Managed runtime

`ManagedRuntimeLayout` derives executable storage and the selected `.harflow` store from an injected home without reading history. `ManagedRuntimeInstaller` performs bounded HTTPS acquisition, verifies pinned bytes, installs only locked binary wheels offline under a private pip environment, qualifies the relocated generation, and atomically activates it under a permanent process lock. Completion receipts bind exact engine version, specification, generation, selected store, and observed engine SHA256/yanked metadata. Existing generations are never replaced or collected. The app bundles the specification as a SwiftPM resource; [maintenance and trust details](../../../docs/managed-runtime.md) describe its inputs.
