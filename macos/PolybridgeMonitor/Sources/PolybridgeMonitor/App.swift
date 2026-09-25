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
    var openWindowOnStart: () -> Bool = { GlobalValues.settingsRepository.openWindowOnStart }
    
    private var launchedAt = Date()
    private var launchedByURL = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAt = now()
        if isRunningAsApp() { setNotificationDelegate(self) }
        // MS-LIST-1/F4-01: discovery → first list → watcher start, exactly once — implemented and
        // tested by `PbRepository.TaskListRepositoryImpl.start()`. The app shell's own job is only to
        // call it once at launch, proven by `AppDelegateTests`.
        startTaskListing()
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
        if now().timeIntervalSince(launchedAt) < 2 { launchedByURL = true }
        MainActor.assumeIsolated {
            for url in urls { coordinator?.handle(url: url) }
        }
    }
    
    // A menu-bar app keeps running with its window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    
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
}

@main
struct PolybridgeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let coordinator: AppCoordinator
    
    init() {
        // Decision 13: modules register (lowest layer first), synchronously, before anything reads
        // `GlobalValues` — `AppCoordinator()` below resolves its feature factories and repositories
        // from `GlobalValues` in its own `init`, so it must run after this line, not before it.
        ApplicationModules(modules: AppModulesRegistry.allModules).initialize()
        
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        delegate.coordinator = coordinator
    }
    
    var body: some Scene {
        Window("Polybridge Monitor", id: "main") {
            coordinator.mainWindowCoordinator.start()
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") { coordinator.handle(path: MonitorDestination.newSession) }.keyboardShortcut("n")
            }
        }
        
        // Settings and the menu bar are built through their own feature coordinators
        // (SettingsFeature/MenuBarFeature) via `AppCoordinator`; nothing in the view layer reads an
        // `AppModel` — that type no longer exists.
        MenuBarExtra {
            coordinator.menuBarNavigationCoordinator?.buildMenuBarContentView() ?? EmptyView().eraseToAnyView()
        } label: {
            coordinator.menuBarNavigationCoordinator?.buildMenuBarLabelView() ?? EmptyView().eraseToAnyView()
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            coordinator.settingsCoordinator.start()
        }
    }
}
