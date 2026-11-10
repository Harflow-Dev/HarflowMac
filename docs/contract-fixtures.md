# Vendored contract fixture provenance

The engine owns the public contracts. MonitorCore tests carry a complete,
self-contained copy of `contracts/v1` from HarflowMCP commit
`6cb13afa729660f631b3069a45a4154c06ec5fa9` (additive pending-launch source contract; no release claim).
No build/test downloads fixtures or requires a sibling checkout.

- Resource path: `macos/HfCore/MonitorCore/Tests/MonitorCoreTests/Resources/ContractsV1`.
- Manifest SHA-256: `f86fbe421ac3dc467265e8ce77756f0b6b70b63c008edd13b4ac1ae03aa65ff9`.
- Contents: 334 fixture files, `manifest.json` and `manifest.sha256`, byte-identical
  to the committed producer bundle. Hash verification covers every fixture.
- Source product version: 0.0.12; historical fixture writer versions intentionally
  vary. Live compatibility is major/minor, not equality with a specimen's patch.
- The separate `contracts/mcp-v1/tools.json` source schema inventory is agent-facing
  and is not vendored or decoded as a ctl document. Its exact Rust subset remains
  Proposed, pending owner acceptance.

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

The Mac's managed specification selects engine 0.0.12 with CPython 3.13.16 and 29
dependencies, matching the vendored bundle's product version. This records the source
pin, not an inspection of an installed runtime or owner state; no installation or
runtime qualification of 0.0.12 has run. The bundle adds the `task-continue.v1`,
`task-artifacts.v1`, `task-continuation-stop.v1` and `task-cancel-cascade.v1`
capabilities. MonitorCore decodes the additive artifact, continuation-stop, cancel-observation and chain-stopped fields; no screen uses them yet. See the [M05 receipt](migration-receipts/M05.md) for the 0.0.12 vendoring evidence.
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
