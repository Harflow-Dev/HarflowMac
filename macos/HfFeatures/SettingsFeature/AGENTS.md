# SettingsFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The Settings scene is built through `SettingsCoordinator`. General shows managed-runtime
status, explicit retry, and behaviour toggles. Tool-directory controls remain hidden. The Harnesses tab exposes explicit MCP registration actions only after managed readiness gates its setup client.

- Swift 6 language mode (tools 6.2 default).
- Depends on `HfUtilities`, `HfCommon`, `HfUI`, `MonitorCore`, `HfRepository`.
- `GeneralSettingsVM` and `HarnessesVM` are independent VMs behind one coordinator; the coordinator
  can build both views for the tab container (`SettingsNavigationView`).
- The Harnesses confirmation dialog is a `ViewModel.publishDialog`, not a bespoke
  `.confirmationDialog`.
- After a successful Harness action only that row updates (`HarnessesVM`); preserve this
  refresh scope unless intentionally changing its behavior.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `HfTestUtilities`.
