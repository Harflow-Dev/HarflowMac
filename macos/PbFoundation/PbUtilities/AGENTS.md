# PbUtilities

Root AGENTS.md applies (`../../AGENTS.md`).

This package holds generic helpers only — nothing here may know about `TaskInfo`, `AlertContent`,
coordinators, or any other Monitor-specific type. If a helper needs an app type, it belongs in
`PbCommon` or higher, not here.

- Swift 6 language mode (tools 6.2 default).
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on `PbTestUtilities` and the test target — match this in any new target you add.
- No `@_exported` re-exports: a consumer that uses `Mockable`/`Dummyable`/`SwiftEnvironment`
  directly must declare that dependency itself, even though this package already depends on them.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`).
