# MonitorCore

Root AGENTS.md applies (`../../AGENTS.md`).

This package is the one deliberate exception to most of the rules there: it is the bottom layer, has
no dependency on `HfUtilities`/`HfCommon`, and predates the Coordinator/VM/UseCase chain — it is
values and I/O, not UI. Keep it that way; architecture-facing code (VMs, repositories, coordinators)
belongs in the packages above it, never here.

- Swift 5 language mode (`swiftLanguageModes: [.v5]`) — see the root AGENTS.md's "Language modes"
  section.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`).

- Continue uses the existing phase-aware launch outcome and one fresh handshake requiring both
  `task-continue.v1` and `task-successors.v1`. Keep pre-dispatch refusal separate from uncertain
  post-dispatch evidence. Acknowledgement can mean pending resources; no automatic launch retry
  or inference from an empty recorded-successor page. This client foundation has no UI callers.
