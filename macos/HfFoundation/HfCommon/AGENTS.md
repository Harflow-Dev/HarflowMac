# HfCommon

Root AGENTS.md applies (`../../AGENTS.md`).

This is the architecture contract layer: types every feature depends on, but no feature-specific
logic. A new `Coordinator`/`ViewModel`/`PathDestination` variant belongs here only if more than one
feature package needs it; a single feature's own VM/UseCase/Routing protocols are declared in that
feature's own screen file (rule 3 in the root AGENTS.md), not here.

- Swift 6 language mode (tools 6.2 default).
- `ViewEvent` has exactly the cases the Monitor uses — do not add a case (e.g. a toast) without a
  decision to change behaviour; see the root AGENTS.md's "ViewEvent" section.
- Feature factory protocols stay minimal. Add methods only when a feature implements them.
- `.define("MOCKING", .when(configuration: .debug))` on `HfCommon`/`HfCommonTestMock`;
  `.define("MOCKING")` (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`).
