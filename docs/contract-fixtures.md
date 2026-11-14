# Vendored contract fixture provenance

The engine owns the public contracts. MonitorCore tests carry a complete,
self-contained copy of `contracts/v1` from HarflowMCP release
commit `a891388b1259add2ec8432d7d0fc5ca38163c27d` (tag `v0.0.14`).
No build/test downloads fixtures or requires a sibling checkout.

- Resource path: `macos/HfCore/MonitorCore/Tests/MonitorCoreTests/Resources/ContractsV1`.
- Manifest SHA-256: `c61bac6e1c3ca00eab4aab4bd1a8f063e98dd91c88365d4f5023127417f432cf`.
- Contents: 351 fixture files, `manifest.json` and `manifest.sha256`, byte-identical
  to the committed producer bundle. Hash verification covers every fixture.
- Source product version: 0.0.14; historical fixture writer versions intentionally
  vary. Live compatibility is major/minor, not equality with a specimen's patch.
- The separate `contracts/mcp-v1/tools.json` source schema inventory is agent-facing
  and is not vendored or decoded as a ctl document. Its exact Rust subset remains
  Proposed, pending owner acceptance.

## Recorded `backends` documents (not part of `contracts/v1`)

`contracts/v1` has no canonical `harflow-ctl backends --json` fixture, and the vendored bundle must stay
byte-identical, so two documents sit beside it in
`macos/HfCore/MonitorCore/Tests/MonitorCoreTests/Resources/RecordedCtl`:

- `ctl-backends-0.0.13-recorded.json`: recorded from the managed 0.0.13 engine run as
  `env -i HOME=<empty scratch directory> PATH=<engine bin>:<directories of the installed harness binaries>`,
  so no real state and no `HARFLOW_*` variable was read. Sanitised: each `identity.executable` is
  `/fixture/bin/<binary>`, each `binary_sha256` is 64 `a`, `platform` is `darwin`, and no absolute path
  under the user's home remains. All six harnesses read `installed: true`. Versions: claude 2.1.322,
  codex 0.167.1, opencode 1.18.21, vibe 3.0.2, agy (antigravity) 1.5.8, cursor-agent 2026.11.11-b912975.
- `ctl-backends-vibe-model-selection-seeded-synthetic.json`: the same document with a single-row
  mutation, vibe's `model_selection` set to `ok: true`, `source: "seeded"`, version `3.0.3`. It is
  synthetic: vibe 3.0.3 could not be recorded.

Both are temporary. The 0.0.14 bundle still has no canonical `contracts/v1/ctl-backends*.json`
specimen (it adds the `ctl-backend-models-*` specimens for `backend-models.v1` only), so both recorded
files stay until a later engine release supplies one.

## Compatibility evidence

The vendored manifest supplies expected format/product version, required
capabilities and validity. New missing-capability handshakes have compatible
base envelopes but fail the named operation's capability check; they must not be
classified as corrupt envelopes. Launch fixtures' `exit_code` values distinguish
accepted task IDs, reported refusal, unknown launch outcome and unsupported usage.
Unknown launch never authorizes automatic replay.

Keep ctl, setup and normalized event gates independent. Unknown optional payload
fields/capability names/event kinds remain additive; embedded normalized events
still need their own provenance/identity validation. Generic payload decoding is
not typed support for every additive feature. Mac adapters do not gain typed support merely by consuming the fixtures. The prompt
client is independently capability-gated; complete activity/event transport remains
a separate M03 slice.

## Runtime boundaries

The Mac's managed specification selects engine 0.0.14 with CPython 3.13.16 and 29
dependencies, matching the vendored bundle's product version. This records the source
pin, not an inspection of an installed runtime or owner state. Isolated installer
qualification of 0.0.14 is recorded in [M03 runtime 0.0.14](migration-receipts/M03-runtime-0014.md). The 0.0.12 bundle added the `task-continue.v1`,
`task-artifacts.v1`, `task-continuation-stop.v1` and `task-cancel-cascade.v1`
capabilities; the 0.0.13 bundle adds `task-pending-launch.v1` (`task-pending-page`, `task-pending-status`), which the pending-launch client and screens require. MonitorCore decodes the additive artifact, continuation-stop, cancel-observation and chain-stopped fields; no screen uses them yet. The 0.0.14 bundle adds `backend-models.v1` (`backend-models`); MonitorCore decodes its `ctl-backend-models-*` specimens (`BackendModelListing`), and no screen uses them yet. See the [M05 receipt](migration-receipts/M05.md) for the 0.0.12, 0.0.13 and 0.0.14 vendoring evidence.
Release changes are separately owned and excluded from migration commits. See [S06 receipt](migration-receipts/S06.md)
for observed validation and remaining acceptance.

## M03-C release-bundle audit

M03-C replaced the complete earlier S05 bundle, not selected examples. The exact
201-file inventories match, and all199 fixture digests validate. Of132 changed
files,130 contain product-version provenance changes;16 opaque cursor values also
change because their integrity hashes cover regenerated synthetic bytes. Independent
old/new byte reconstruction reproduced every event anchor/head and changes-document
digest. Scope, generation, paging direction, boundary, sequence, filter and position
are unchanged; no unexpected semantic delta was found. Manifest case metadata
differs only by the corresponding expected version. The consumer copied bytes
unchanged from immutable Git objects and never regenerated tokens. See the
[exact audit](migration-receipts/M03-C-fixture-audit.json). Runtime and producer
acceptance remain separate from this consumer-data adoption.
