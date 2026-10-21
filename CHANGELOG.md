# Changelog

## Unreleased

- Add unsigned release validation and protected product signing, notarization and release-asset workflows.

- Prepare and reuse the exact paired managed runtime with pinned Python and dependency wheels, offline installation, and qualified immutable generations.
- Add shared runtime status and explicit retry; restore readiness-gated Harnesses MCP registration with stable launchers that survive app relocation or removal.

- Set the initial product version to 0.0.1 while preserving v1 wire and storage contracts.

- Extract native macOS packages with preserved source history.
- Adopt Harflow application and Hf module identities.
- Use the supplied Harflow application and menu bar artwork.
- Disable runtime execution and installation pending managed runtime integration.
- Validate explicit Harflow v1 wire identities and per-operation runtime compatibility before commands and store reads.
