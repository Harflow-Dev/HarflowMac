# SettingsFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The Settings scene is built through `SettingsCoordinator`. General shows, in order, an Appearance theme control (System, Light, Dark; shares `SettingsRepository.appAppearance` with the sidebar footer), the behaviour toggles, the Harflow runtime row and the Task store row (`GeneralSettingsGroup`). Backup, reset, resume and Show backup in Finder stay hidden (`StoreRecoveryPresentation.recoveryActionsAvailable`). There is no tool-directory control or setting. The Harnesses tab exposes explicit MCP registration actions only after managed readiness gates its setup client.

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

The Task store row shows a refusal's engine sentence (`ToolError.displayMessage`) without its code. The refusal code appears only as a "Code" detail row, and only when the refusal carries no engine reason or the inspection itself failed; the reason, title and state root come from `HfRepository.StoreAttention`.
