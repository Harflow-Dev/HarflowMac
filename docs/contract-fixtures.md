# Vendored contract fixture provenance

The engine owns the public contracts. MonitorCore tests carry a complete,
self-contained copy of `contracts/v1` from HarflowMCP commit
`b69b5754a7b6496aaf5e3106116e302ea7a10675` (S05, local producer commit).
No build/test downloads fixtures or requires a sibling checkout.

- Resource path: `macos/HfCore/MonitorCore/Tests/MonitorCoreTests/Resources/ContractsV1`.
- Manifest SHA-256: `383ecf7a9b234a1ece18eb15585398f08a77205c02a43cb2a928a2819f76fee0`.
- Contents: 199 fixture files, `manifest.json` and `manifest.sha256`, byte-identical
  to the committed producer bundle. Hash verification covers every fixture.
- Source product version: 0.0.7; historical fixture writer versions intentionally
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
not typed support for every additive feature. Legacy Mac adapters need not adopt
S04 reads merely to consume the new fixtures; Electron will use transport-neutral
ports and ctl/setup, with each operation independently capability-gated.

## Runtime boundaries

Fixture adoption does not change Mac's selected source runtime: its managed
specification remains engine 0.0.7 with CPython 3.13.16 and 29 dependencies.
This records the source pin, not an inspection of an installed runtime or owner
state. The owner intends engine 0.0.8 for Electron development; S06 does not claim
that release is published, installed or qualified. Release changes are separately
owned and excluded from migration commits. See [S06 receipt](migration-receipts/S06.md)
for observed validation and remaining acceptance.
