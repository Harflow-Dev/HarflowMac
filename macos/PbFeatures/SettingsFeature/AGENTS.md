# SettingsFeature

Root AGENTS.md applies (`../../AGENTS.md`).

The Settings scene: General (tool directory + behaviour toggles) and Harnesses (MCP client
install/remove). Built through `SettingsCoordinator`, wired into the app's `Settings` scene.

- Swift 6 language mode (tools 6.2 default).
- Depends on `PbUtilities`, `PbCommon`, `PbUI`, `MonitorCore`, `PbRepository`.
- `GeneralSettingsVM` and `HarnessesVM` are independent VMs behind one coordinator; the coordinator
  builds both views for the tab container (`SettingsView`).
- The Harnesses confirmation dialog is a `ViewModel.publishDialog`, not a bespoke
  `.confirmationDialog` — copy stays byte-identical to the old `SettingsView.swift`.
- Existing issue, preserved on purpose: after a successful Harness action only that row updates
  (`HarnessesVM`), even though the old code's comment says "a fresh status for everything." Do not
  "fix" this — see the settled plan's "Existing issues" section.
- `.define("MOCKING", .when(configuration: .debug))` on the main target; `.define("MOCKING")`
  (unconditional) on the test target.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types, and `waitUntil` from `PbTestUtilities`.
