import AppKit
import MonitorCore
import PbCommon
import PbRepository
import PbUtilities
import SwiftEnvironment
import SwiftUI
@preconcurrency import UserNotifications

/// `NSApplicationDelegate`'s lifecycle methods (and `UNUserNotificationCenterDelegate`'s, which can
/// genuinely be invoked off the main thread by the system) are not themselves `@MainActor`-isolated,
/// so this type stays non-isolated too, exactly as before Phase 5 — every access to main-actor state
/// (`coordinator`, the injected AppKit/repository seams) is wrapped in `MainActor.assumeIsolated`, or
/// (for `userNotificationCenter(_:didReceive:withCompletionHandler:)`, which cannot assume that: see
/// its own header) an explicit `Task { @MainActor in }` hop.
///
/// **`@unchecked Sendable`**: a Codex review round on this exact type caught that marking
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)` itself `@MainActor` (an earlier
/// version of this fix) compiles, but is not runtime-safe — Swift inserts a dynamic executor check
/// into that method's Objective-C entry point (confirmed by disassembling the compiled object:
/// `_checkExpectedExecutor`), which **traps** if UserNotifications ever calls it off the main thread,
/// exactly the case `@preconcurrency import UserNotifications` above does not protect against. The
/// fix is the one below: the method stays nonisolated (matching the protocol's actual, unannotated
/// requirement) and explicitly hops via `Task { @MainActor in }`, the same shape
/// `DispatchQueue.main.async { MainActor.assumeIsolated { } }` gave HEAD, but expressed with
/// structured concurrency. Capturing `self` across that hop needs `@unchecked Sendable` on the whole
/// type — safe here because every stored property this delegate holds is either read only from a
/// context AppKit itself guarantees is the main thread (`launchedAt`/`launchedByURL`, mutated only
/// from `NSApplicationDelegate` methods), or already `@MainActor`-isolated in its own right
/// (`coordinator`), so nothing this hop reaches is ever genuinely raced.
///
/// **Testable seams** (item 3 of the Phase 5 brief: "put the timer and launch decisions behind small
/// testable seams — an injectable clock/scheduler and a window-hiding closure — so the 0.8 s / 2 s
/// rules get tests without sleeping"). Every default matches production behaviour exactly; tests
/// override them to drive MS-APP-1/F4-29 without a real timer, a real bundle, or real windows.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, @unchecked Sendable {
    
    /// Set by `PolybridgeMonitorApp.init()` right after it constructs `AppCoordinator` —
    /// `@NSApplicationDelegateAdaptor` builds this instance before that `init()` body runs, so the
    /// assignment lands before `applicationDidFinishLaunching`/`application(_:open:)` can fire. `any
    /// Coordinator` (not the concrete `AppCoordinator`) so a test can inject a `MockCoordinator`.
    /// `@MainActor`-isolated: every access is already inside a `MainActor.assumeIsolated` block below
    /// (this delegate's own methods are not themselves isolated — see this type's header), and
    /// isolating the property itself is what lets Swift 6 prove those accesses race-free.
    @MainActor var coordinator: (any Coordinator)?
    
    var now: () -> Date = Date.init
    var scheduleAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { action() }
        }
    }
    
    var isRunningAsApp: () -> Bool = { Bundle.main.bundleURL.pathExtension == "app" }
    var mainWindows: @MainActor () -> [NSWindow] = {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
    }
    
    var orderOutWindow: @MainActor (NSWindow) -> Void = { $0.orderOut(nil) }
    var setNotificationDelegate: (UNUserNotificationCenterDelegate) -> Void = {
        UNUserNotificationCenter.current().delegate = $0
    }
    
    var startTaskListing: () -> Void = { GlobalValues.taskListRepository.start() }
    var startBackendsCatalog: () -> Void = { GlobalValues.backendsRepository.start() }
    var notifyBackendsAppActive: () -> Void = { GlobalValues.backendsRepository.appDidBecomeActive() }
    var openWindowOnStart: () -> Bool = { GlobalValues.settingsRepository.openWindowOnStart }

    // MARK: - Single instance (Monitor piece 9) seams

    /// A snapshot of every running application — the raw input to `SingleInstanceGuard`. Plain
    /// (not `@MainActor`) like `isRunningAsApp`/`selfBundleIdentifier`/`selfBundleURL`/
    /// `selfProcessIdentifier` below: these read process/bundle state, not AppKit UI state.
    var runningApplications: () -> [RunningAppSnapshot] = {
        NSWorkspace.shared.runningApplications.map(RunningAppSnapshot.init(runningApplication:))
    }

    var selfBundleIdentifier: () -> String? = { Bundle.main.bundleIdentifier }
    var selfBundleURL: () -> URL? = { Bundle.main.bundleURL }
    var selfProcessIdentifier: () -> pid_t = { ProcessInfo.processInfo.processIdentifier }

    /// Forwards buffered `application(_:open:)` URLs to the already-running instance. The
    /// `NSWorkspace.OpenConfiguration` is built by the caller (`forwardURLBatch`) so a test can
    /// inspect its exact flags rather than only observing that *some* configuration was passed.
    var forwardURLs: @MainActor (
        [URL], URL, NSWorkspace.OpenConfiguration, @escaping @MainActor (Result<Void, Error>) -> Void
    ) -> Void = { urls, bundleURL, configuration, completion in
        NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    /// Asks the already-running instance to reopen (bring a window forward), for a plain
    /// (no-URL) duplicate launch. Never `NSRunningApplication.activate` and never a bare `open` —
    /// see the settled plan's review round 2.
    var requestReopen: @MainActor (
        URL, NSWorkspace.OpenConfiguration, @escaping @MainActor (Result<Void, Error>) -> Void
    ) -> Void = { bundleURL, configuration, completion in
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    var terminateApp: @MainActor () -> Void = { NSApp.terminate(nil) }

    /// Bridges the guard's decision into SwiftUI — see this type's own declaration for how
    /// `PolybridgeMonitorApp.body` uses it. `@MainActor`-isolated for the same reason as
    /// `coordinator` above: its default value construction runs on the main actor, and every
    /// access to it below is already inside a `MainActor.assumeIsolated` block.
    @MainActor let singleInstanceState = SingleInstanceState()

    private var launchedAt = Date()
    private var launchedByURL = false
    private var hasHandledURLs = false
    /// `false` only when AppKit says the launch was not a plain one (it came to open something);
    /// a missing key keeps the time rule alone.
    private var launchWasDefault: Bool?

    /// Set by `applicationWillFinishLaunching` when this launch is a duplicate; `nil` for the
    /// normal, single-instance path. Every other single-instance seam (`application(_:open:)`,
    /// `applicationDidFinishLaunching`, `applicationShouldHandleReopen`) branches on this.
    private var duplicateOf: RunningAppSnapshot?
    /// Counts in-flight forward/reopen requests. A duplicate terminates only once this reaches
    /// zero — see `endOperationAndMaybeTerminate()`.
    private var pendingOperations = 0
    private var terminated = false

    /// Best-effort single-instance guard (Monitor piece 9): if another non-terminated process
    /// with this app's own bundle identifier is already running from a **different** bundle path,
    /// this launch is a duplicate. `SingleInstanceGuard.findDuplicate` is the pure rule; this
    /// method only wires it to real AppKit state and records the result for
    /// `applicationDidFinishLaunching`, `application(_:open:)` and `applicationShouldHandleReopen`
    /// to act on. Runs before `applicationDidFinishLaunching` and before AppKit delivers any
    /// launch `application(_:open:)` batch, so every other single-instance branch below can rely
    /// on `duplicateOf` already being decided.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard isRunningAsApp() else { return }
        MainActor.assumeIsolated {
            guard let duplicate = SingleInstanceGuard.findDuplicate(
                among: runningApplications(),
                selfBundleIdentifier: selfBundleIdentifier(),
                selfBundleURL: selfBundleURL(),
                selfProcessIdentifier: selfProcessIdentifier()
            ) else { return }
            duplicateOf = duplicate
            singleInstanceState.isPrimaryInstance = false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAt = now()
        launchWasDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool

        if let duplicate = duplicateOf {
            // Best-effort duplicate shutdown (settled plan, section 3): skip task listing,
            // notification-delegate registration, and the normal 0.8 s launch-hiding timer
            // entirely — none of it matters for a process about to hand over and quit.
            MainActor.assumeIsolated {
                guard let existingBundleURL = duplicate.bundleURL else {
                    terminateOnce()
                    return
                }
                scheduleDeadlineTermination()
                startHidingDuplicateWindows()
                // One run-loop turn: give any `application(_:open:)` batch AppKit already queued a
                // chance to land before deciding this was a plain (no-URL) launch.
                scheduleAfter(0) { [self] in
                    MainActor.assumeIsolated {
                        guard !hasHandledURLs else { return }
                        sendReopenRequest(to: existingBundleURL)
                    }
                }
            }
            return
        }

        if isRunningAsApp() { setNotificationDelegate(self) }
        // MS-LIST-1/F4-01: discovery → first list → watcher start, exactly once — implemented and
        // tested by `PbRepository.TaskListRepositoryImpl.start()`. The app shell's own job is only to
        // call it once at launch, proven by `AppDelegateTests`.
        startTaskListing()
        // Monitor piece 6: the backends catalog's own startup fetch, exactly once — implemented and
        // tested by `PbRepository.BackendsRepositoryImpl.start()`.
        startBackendsCatalog()
        // SwiftUI opens the main window at launch. When the launch came from a task starting
        // (`open -g polybridge-monitor://task/<id>`) and the user asked not to have the window
        // come forward, put it away again; a launch by hand keeps it.
        scheduleAfter(0.8) { [self] in
            MainActor.assumeIsolated {
                guard launchedByURL, !openWindowOnStart() else { return }
                mainWindows().forEach(orderOutWindow)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let withinLaunchWindow = now().timeIntervalSince(launchedAt) < 2
        if withinLaunchWindow { launchedByURL = true }
        // Only the first batch of a launch that came to open something is the one that launched the
        // app; a task starting a second later — or just after a launch by hand — finds a window the
        // user may already be looking at, and must leave it alone.
        let isLaunchBatch = withinLaunchWindow && !hasHandledURLs && launchWasDefault != true
        hasHandledURLs = true
        MainActor.assumeIsolated {
            // A duplicate never routes a URL to its own coordinator — however late it arrives, or
            // however many batches AppKit delivers, each one is forwarded to the running instance
            // instead. `forwardURLBatch` keeps `pendingOperations` above zero until this forward's
            // own completion, so a batch arriving after a reopen was already sent still gets
            // forwarded before the process quits.
            if let duplicate = duplicateOf {
                guard let existingBundleURL = duplicate.bundleURL else { return }
                forwardURLBatch(urls, to: existingBundleURL)
                return
            }
            for url in urls {
                if isLaunchBatch, let launchHandler = coordinator as? LaunchURLHandling {
                    launchHandler.handleLaunchURL(url)
                } else {
                    coordinator?.handle(url: url)
                }
            }
        }
    }
    
    // A regular Dock app that also has a menu bar item keeps running after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Monitor piece 6's "app activation" refresh point (Review round 1 item 1): fires on every
    /// activation, unconditionally — the 60 s bound lives in `BackendsRepositoryImpl` itself, not
    /// here, so this stays a plain forwarding call with nothing to test beyond "it forwards."
    func applicationDidBecomeActive(_ notification: Notification) {
        notifyBackendsAppActive()
    }

    /// Decision 3's reopen handling: decided from the `mainWindows()` seam, never from `hasVisibleWindows`
    /// (that flag is `true` when only Settings or the menu-bar panel is open, which is not a main
    /// window). If no main window is currently visible — none exist, one is miniaturized, or one is
    /// merely ordered out — route `.openWindow` through the coordinator; opening twice is harmless,
    /// since `openWindow(id:)` on a single `Window` only brings it forward. Always returns `true`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            // A duplicate never handles reopen locally — it has no coordinator worth reopening
            // into, and is already on its way out.
            guard duplicateOf == nil else { return }
            let hasVisibleMainWindow = mainWindows().contains { $0.isVisible && !$0.isMiniaturized }
            if !hasVisibleMainWindow { coordinator?.handle(path: MonitorDestination.openWindow) }
        }
        return true
    }

    /// Deliberately **not** `@MainActor` — see this type's own header for why a synchronous
    /// `@MainActor` witness of this specific method is a real (Codex-caught) runtime trap, not just a
    /// style choice. `completionHandler()` is called immediately, without waiting on the hop, exactly
    /// as HEAD's `DispatchQueue.main.async { … }; completionHandler()` never waited on its dispatch
    /// either.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            self.handleNotificationClick(userInfo: userInfo)
        }
        completionHandler()
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(foregroundPresentationOptions())
    }
    
    /// Pulled out of `userNotificationCenter(_:didReceive:withCompletionHandler:)` so a test can
    /// drive it with a plain `userInfo` dictionary — `UNNotificationResponse`/`UNNotification` have
    /// no public initializer, so constructing a real one is not an option here.
    @MainActor
    func handleNotificationClick(userInfo: [AnyHashable: Any]) {
        guard let id = userInfo["task_id"] as? String, MonitorURL.isValidTaskID(id) else { return }
        // Always shows the window, regardless of `openWindowOnStart` (F4-32) — unlike `handle(url:)`,
        // which is conditional. `.openWindow` reaches `AppCoordinator.handle(path:)`'s own
        // `case .openWindow:` unconditionally.
        coordinator?.handle(path: MonitorDestination.task(id))
        coordinator?.handle(path: MonitorDestination.openWindow)
    }
    
    /// Pulled out of `userNotificationCenter(_:willPresent:withCompletionHandler:)` for the same
    /// reason as `handleNotificationClick(userInfo:)` above.
    func foregroundPresentationOptions() -> UNNotificationPresentationOptions { [.banner, .sound] }

    // MARK: - Single instance (Monitor piece 9)

    @MainActor
    private func scheduleDeadlineTermination() {
        // Bounded exit (settled plan, review round 2): terminates even if a forward/reopen
        // completion never arrives. No retry loop — this fires exactly once, and `terminateOnce()`
        // guards against a completion that arrives afterward terminating a second time.
        scheduleAfter(3.0) { [self] in
            MainActor.assumeIsolated { self.terminateOnce() }
        }
    }

    /// Repeats on a short main-queue hop (rather than observing window-creation notifications) so
    /// the whole mechanism stays expressible with the existing `scheduleAfter`/`mainWindows`/
    /// `orderOutWindow` seams: a main window SwiftUI mounts *after* this method starts polling
    /// still gets ordered out within one hop — a brief flash is accepted, per the settled plan.
    /// Stops once `terminateOnce()` has fired, since the process is about to exit anyway.
    @MainActor
    private func startHidingDuplicateWindows() {
        guard !terminated else { return }
        mainWindows().forEach(orderOutWindow)
        scheduleAfter(0.05) { [self] in
            MainActor.assumeIsolated { self.startHidingDuplicateWindows() }
        }
    }

    @MainActor
    private func terminateOnce() {
        guard !terminated else { return }
        terminated = true
        terminateApp()
    }

    /// `pendingOperations` counts every in-flight forward/reopen request. A duplicate terminates
    /// only once it reaches zero — which is what lets a URL arriving after a reopen was already
    /// sent (but before it completed) still get forwarded before the app quits, with no explicit
    /// ordering logic: the late forward simply keeps the count above zero until it too completes.
    @MainActor
    private func beginOperation() { pendingOperations += 1 }

    @MainActor
    private func endOperationAndMaybeTerminate() {
        pendingOperations -= 1
        guard pendingOperations <= 0 else { return }
        terminateOnce()
    }

    @MainActor
    private func forwardURLBatch(_ urls: [URL], to existingBundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = false
        beginOperation()
        forwardURLs(urls, existingBundleURL, configuration) { [self] _ in
            // An error is still followed by termination (settled plan) — there is nothing more
            // useful this process can do with a forward that failed.
            endOperationAndMaybeTerminate()
        }
    }

    @MainActor
    private func sendReopenRequest(to existingBundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = false
        beginOperation()
        requestReopen(existingBundleURL, configuration) { [self] _ in
            endOperationAndMaybeTerminate()
        }
    }
}

/// Bridges `AppDelegate`'s single-instance decision into SwiftUI (Monitor piece 9):
/// `PolybridgeMonitorApp.body` binds `MenuBarExtra(isInserted:)` to `isPrimaryInstance`, so a
/// duplicate never shows the menu-bar item. Set to `false` in `applicationWillFinishLaunching`,
/// which runs before any `Scene` body has ever rendered when it can — but if `MenuBarExtra` has
/// already inserted by the time that runs, flipping the binding just removes it a moment later. A
/// brief flash either way is accepted, per the settled plan.
@MainActor
@Observable
final class SingleInstanceState {
    var isPrimaryInstance = true
}

/// Decision 8's menu-bar icon: an uncached `NSImage` carrying both the 1x and @2x
/// `menubarTemplate*.png` representations bundled at `Resources/`, marked as a template image so
/// AppKit tints it for light/dark mode and menu-bar highlighting. Returns `nil` when the bundle has
/// no such resource (e.g. a test bundle with no `Resources/`), in which case callers fall back to the
/// SF Symbol `MenuBarLabelView` already draws.
func loadMenuBarIcon(from bundle: Bundle) -> NSImage? {
    guard let image = bundle.image(forResource: "menubarTemplate") else { return nil }
    image.isTemplate = true
    return image
}

@main
struct PolybridgeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let coordinator: AppCoordinator
    private let menuBarIcon: NSImage?

    init() {
        // Decision 13: modules register (lowest layer first), synchronously, before anything reads
        // `GlobalValues` — `AppCoordinator()` below resolves its feature factories and repositories
        // from `GlobalValues` in its own `init`, so it must run after this line, not before it.
        ApplicationModules(modules: AppModulesRegistry.allModules).initialize()

        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        // Loaded once here, never inside `body` — `body` can be re-evaluated many times per process.
        // Every stored property must be set before `self` is used at all (below), which is why this
        // assignment comes before `delegate.coordinator = coordinator`.
        self.menuBarIcon = loadMenuBarIcon(from: .main)
        delegate.coordinator = coordinator
    }
    
    var body: some Scene {
        Window("Polybridge Monitor", id: "main") {
            MainWindowSceneRoot(windowPresenting: coordinator) {
                coordinator.mainWindowCoordinator.start()
            }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { coordinator.handle(path: MonitorDestination.newSession) }.keyboardShortcut("n")
            }
        }
        
        // Settings and the menu bar are built through their own feature coordinators
        // (SettingsFeature/MenuBarFeature) via `AppCoordinator`; nothing in the view layer reads an
        // `AppModel` — that type no longer exists.
        //
        // `isInserted` is bound to `SingleInstanceState.isPrimaryInstance` (Monitor piece 9): a
        // duplicate instance never shows the menu-bar item.
        MenuBarExtra(isInserted: Binding(
            get: { delegate.singleInstanceState.isPrimaryInstance },
            set: { delegate.singleInstanceState.isPrimaryInstance = $0 }
        )) {
            coordinator.menuBarNavigationCoordinator?.buildMenuBarContentView() ?? EmptyView().eraseToAnyView()
        } label: {
            coordinator.menuBarNavigationCoordinator?.buildMenuBarLabelView(icon: menuBarIcon) ?? EmptyView().eraseToAnyView()
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            coordinator.settingsCoordinator.start()
        }
    }
}
