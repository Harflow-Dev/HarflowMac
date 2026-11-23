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

Harnesses draws no install banner. It follows the managed runtime's `RuntimeSetupState` (seeded from `HarnessesUseCase.runtimeSetupState`): while it is not ready the list and the qualification section give way to a note with Open setup (`HarnessesRouting.openSetup()`, routed by `SettingsCoordinator` to the main window), Refresh is disabled and nothing is loaded. When ready, a failed status load (refusal, unsupported setup version, unreadable, timeout or launch failure) shows the refusal's `displayMessage`, a Code `DetailLine` from `ToolError.detailCode` when there is one, and Retry, with no rows and no server path; an empty setup document shows "No harnesses found on this Mac."; the qualification section stays in both. A failed install, update or removal is kept per row (`HarnessRowFailure`), replaces that row's actions with Retry, and Retry repeats the action after the same confirmation. Final copy for the missing-capability states belongs to the harness settings design pinned at HarflowDesign `8ec4d38`. A task store inspection that the runtime does not support (`state-inspect` unsupported) shows `MissingFeature.sentence(canDo: "inspect the task store")` in the Task store row, with no Code line.

`StoreRecoveryPanel` still draws its own monospaced value rather than `DetailLine`; adopting the shared line there is a follow-up.
