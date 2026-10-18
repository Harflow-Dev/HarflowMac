# Harflow

Root AGENTS.md applies (`../AGENTS.md`).

The app shell: startup, lifecycle, and the root of the coordinator tree. Nothing here renders a
screen directly — every `Window`/`MenuBarExtra`/`Settings` scene body builds its content through a
feature coordinator (`AppCoordinator.mainWindowCoordinator`/`menuBarNavigationCoordinator`/
`settingsCoordinator`, from the `GlobalValues` feature factories).

- Swift 6 language mode (tools 6.2 default); see the shared "Language modes" rules.
- `AppModulesRegistry.allModules` lists every application module, lowest layer first: `HfRepository`,
  then `SettingsFeature`/`MenuBarFeature`/`MainWindowFeature`. `HfUtilities`/`HfCommon`/
  `HfUI`/`MonitorCore` have no `Module` of their own. `HarflowApp.init()` runs
  `ApplicationModules(modules: AppModulesRegistry.allModules).initialize()` synchronously — its three
  phases (`modulesWillInitialize`/`initializeModule`/`modulesDidInitialize`, in that order across
  every module) are what let a later module's initializer resolve a value an earlier one just
  registered, and only a value registered during the initialize phase itself waits for
  `modulesDidInitialize`.
- `AppCoordinator` is built immediately after that call, in the same `init()`: every scene renders straight away with whatever not-yet-listed state the repositories
  start in ("connecting…"), and a URL/notification arriving before any scene has rendered still works
  (`mainWindowCoordinator`/`menuBarCoordinator`/`settingsCoordinator` are `lazy var`s on
  `AppCoordinator`, so the first access — from wherever it comes — builds them).
- `AppCoordinator.handle(path:)` for `MonitorDestination`: `.task`/`.group` delegate
  to `mainWindowCoordinator.handle(path:)` (which owns `selection`/`presentedSheet`);
  `.newSession` first brings the window forward, then delegates the same way; `.openWindow` goes
  through `WindowPresenting` (`NSApp.activate(ignoringOtherApps: true)`, then the registered opener).
  The opener is registered by `MainWindowSceneRoot.onAppear` (the main window's scene root) and, as a
  second route, by `MenuBarLabelView.onAppear` via `MenuBarCoordinator.registerWindowOpener`. A Dock
  click with no visible main window reopens it through `AppDelegate.applicationShouldHandleReopen`.
  `handle(url:)` accepts `harflow://task/<id>`; an invalid URL is ignored. A valid one, when the main window is
  already visible (`isMainWindowVisible`, same identifier-prefix/visible/not-miniaturized rule as
  `mainWindows()` above, plus `NSApp.isHidden` so ⌘H counts as not visible), only fires a
  fire-and-forget `TaskListRepository.refresh()` — no selection change, no sidebar reveal, no
  activation, no window re-order, regardless of the toggle. The first batch of URLs within 2 s of a
  launch AppKit did not report as a plain one (`launchIsDefaultUserInfoKey` not `true`;
  `AppDelegate.application(_:open:)` decides, from its own launch clock) goes through
  `LaunchURLHandling.handleLaunchURL(_:)` instead, which always selects — the window then is the one
  SwiftUI opened by itself; later batches take the visibility rule. Only when the window is *not*
  visible does it fall back to the previous behaviour: select the task (+ reveal, via
  `handle(path:)`), refresh, and bring the window forward only when `SettingsRepository.openWindowOnStart` is on. A
  notification click instead calls `handle(path:)` for `.task` then `.openWindow` directly, which
  always brings the window forward (F4-32) regardless of visibility or the toggle.
- `AppDelegate` stays **not** globally `@MainActor` (its `NSApplicationDelegate` methods aren't
  isolated by the SDK, and `UNUserNotificationCenterDelegate`'s can be invoked off the main thread) —
  every access to main-actor state is wrapped in `MainActor.assumeIsolated` or lives behind a
  `@MainActor`-isolated conformance clause (`@MainActor UNUserNotificationCenterDelegate`). Its timer,
  clock, bundle, window, and repository touch points are all injectable seams (`now`, `scheduleAfter`,
  `isRunningAsApp`, `mainWindows`, `orderOutWindow`, `setNotificationDelegate`, `startTaskListing`,
  `openWindowOnStart`) so the 0.8 s/2 s launch rules (MS-APP-1) and the notification-delegate rule
  (F4-29) get tests without a real timer, a real bundle, or a real notification center.
  `handleNotificationClick(userInfo:)` and `foregroundPresentationOptions()` are pulled out of the two
  `UNUserNotificationCenterDelegate` methods for the same testability reason — `UNNotification`/
  `UNNotificationResponse` have no public initializer, so a test drives the plain-dictionary/no-input
  helpers directly instead.
- **Single instance (best-effort — not guaranteed).** Two bundle paths of the same
  app (e.g. an installed `/Applications/Harflow.app` and a freshly built
  `macos/build/Harflow.app`) can otherwise both run at once, since macOS treats each
  bundle path as its own app. `SingleInstanceGuard.findDuplicate` (`SingleInstanceGuard.swift`) elects
  the oldest **non-terminated** process with this app's own bundle identifier across **different**
  bundle paths. Launch dates order candidates, with PID breaking ties; known dates precede unknown
  dates. Only a copy outranked by another yields, preventing reciprocal shutdown during concurrent
  launches. A terminated match or a same-path match is ignored.
  `AppDelegate.applicationWillFinishLaunching` runs it once, before any launch `application(_:open:)`
  batch or `applicationDidFinishLaunching` — every other single-instance branch relies on that
  ordering. A duplicate: skips task listing, notification-delegate registration, and the normal
  0.8 s launch-hiding timer; flips `SingleInstanceState.isPrimaryInstance` to `false`, which
  `HarflowApp.body` binds to `MenuBarExtra(isInserted:)` so the menu-bar item never shows
  (a brief flash before removal is accepted if the scene already inserted); repeatedly orders out
  any "main"-identified window on a short (`0.05 s`) `scheduleAfter` hop, since `Window` scenes have
  no `isInserted` equivalent to gate; forwards every `application(_:open:)` URL batch — however late,
  however many — to the running instance via `NSWorkspace.open(_:withApplicationAt:configuration:)`
  (`activates = false`, `allowsRunningApplicationSubstitution = false`,
  `createsNewApplicationInstance = false`); and, if no URL arrived within one run-loop turn of
  `applicationDidFinishLaunching`, sends a **reopen** instead via
  `NSWorkspace.openApplication(at:configuration:)` (`activates = true`, same substitution/new-instance
  flags) — never a bare `NSRunningApplication.activate` or `open`. `applicationShouldHandleReopen`
  never handles reopen locally for a duplicate. **Bounded exit:** `pendingOperations` counts every
  in-flight forward/reopen request and terminates only once it reaches zero — which is what lets a
  URL arriving after a reopen was already sent, but before it completed, still get forwarded before
  the app quits — and a ~3 s deadline terminates unconditionally even if a completion never arrives;
  `terminateOnce()` guards against terminating twice. Every AppKit touch point is one more injected
  seam on `AppDelegate` (`runningApplications`, `selfBundleIdentifier`/`selfBundleURL`/
  `selfProcessIdentifier`, `forwardURLs`, `requestReopen`, `terminateApp`), tested in
  `AppDelegateSingleInstanceTests.swift` with no real timer, no real `NSWorkspace` call, and no real
  running app.
- `AppCoordinator` owns app coordination. References to removed `AppModel` or
  `TransitionalAppCoordinator` types are stale outside historical source comments.
- Depends on `MonitorCore`, `HfRepository`, `HfUtilities`, `HfCommon`,
  `SettingsFeature`, `MenuBarFeature`, `MainWindowFeature`, and (remote) SwiftEnvironment 4.1.8. Does
  **not** depend on `HfUI` — nothing in this target imports it (every UI component this app renders
  comes from a feature package).
- SwiftPM can `@testable import` an executable target from a test target in the same package — the
  test target here does exactly that (`HarflowTests`), rather than needing a separate
  library target.
- `.define("MOCKING")` (unconditional) on the test target — this target has no `MOCKING`-gated debug
  code of its own (no `@Mockable` protocol is declared here), but the test target still needs it to
  see the `Mock*` types generated by the packages it imports.
- Tests use Swift Testing (`givenX_whenY_thenZ`, `// given / when / then`), Mockable-generated
  `Mock*` types from the packages this target depends on, and hand-written fakes where a protocol
  isn't `@Mockable` (`FakeMainWindowNavigationCoordinator`, mirroring
  `HfCommonTestMock.ViewChildCoordinatorMock`'s own reason for existing — `MainWindowNavigationCoordinator`
  is not itself `@Mockable`).
