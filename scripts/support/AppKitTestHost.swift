import AppKit
import Darwin
import Testing

// MARK: - ExceptionTerminationEvidence

/// Set immediately before the deliberate raise and read from the signal handler: an unrelated
/// SIGABRT or SIGTRAP during the self-test must not print the identity line. `sig_atomic_t`
/// is the type the C standard guarantees is safe to read and write from a signal handler.
private nonisolated(unsafe) var exceptionSelfTestDeliberatelyRaised: sig_atomic_t = 0

/// Post-raise evidence for the exception self-test. With `NSApplicationCrashOnExceptions`
/// registered, the ObjC exception handler terminates through a hardware trap and never runs
/// the uncaught-exception handler, so nothing else would print the identity: this bounded
/// signal handler writes the pre-encoded `APPKIT_EXCEPTION` line — the exact format of the
/// uncaught handler below, carrying the same constant exception name and self-test reason as
/// the raise in `runExceptionSelfTest` — to stderr with async-signal-safe `write`, then
/// restores the default disposition and re-raises, so the process still dies by signal. The
/// line is only written for the deliberate raise (the flag set immediately beforehand); an
/// unrelated trap still restores SIG_DFL and re-raises, but without the identity, so the
/// runner rejects it. The line is a compile-time literal because a signal handler may not
/// allocate or call into Swift runtime code; keep the name and reason in sync with
/// `runExceptionSelfTest`.
private func exceptionSelfTestTerminationHandler(_ signalNumber: CInt) {
    if exceptionSelfTestDeliberatelyRaised != 0 {
        let line: StaticString = "APPKIT_EXCEPTION name=NSInvalidArgumentException reason=AppKitTestHost exception self-test\n"
        _ = write(2, UnsafeRawPointer(line.utf8Start), line.utf8CodeUnitCount)
    }
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

// MARK: - Host defaults

/// The two settings that disable state restoration, applied through the volatile argument domain.
/// That domain outranks every persistent domain and is never written to disk, so the host leaves
/// no `dev.harflow.testhost.<id>.plist` behind in the real Preferences folder (the scratch HOME
/// does not redirect cfprefsd).
private let hostDefaultsOverrides: [(key: String, value: Bool)] = [
    ("ApplePersistenceIgnoreState", true),
    ("NSQuitAlwaysKeepsWindows", false)
]

/// Merges the overrides into the existing argument domain; never replaces it.
private func applyHostDefaultsOverrides() {
    let defaults = UserDefaults.standard
    var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    for override in hostDefaultsOverrides {
        domain[override.key] = override.value
    }
    defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
}

/// The first effective value that differs from the override, or nil when all hold.
private func effectiveDefaultsProblem() -> String? {
    let defaults = UserDefaults.standard
    for override in hostDefaultsOverrides {
        let effective = defaults.object(forKey: override.key) as? Bool
        if effective != override.value {
            return "\(override.key) is \(effective.map(String.init(describing:)) ?? "unset"), expected \(override.value)"
        }
    }
    return nil
}

/// Verifies the NSUserDefaults layer at the end of a run: the effective overrides still hold and the
/// host's own persistent domain is empty or nil. Prints the single receipt line the runner requires
/// on stderr, or a distinct failure line, and returns whether the host may exit successfully. AppKit
/// reads that bypass NSUserDefaults are not covered by this check.
private func verifyHostDefaultsAtExit() -> Bool {
    func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    if let problem = effectiveDefaultsProblem() {
        report("APPKIT_DEFAULTS effective=invalid \(problem)")
        return false
    }
    guard let identifier = Bundle.main.bundleIdentifier else {
        report("APPKIT_DEFAULTS persistent=unknown no bundle identifier")
        return false
    }
    if let domain = UserDefaults.standard.persistentDomain(forName: identifier), !domain.isEmpty {
        report("APPKIT_DEFAULTS persistent=non-empty keys=\(domain.keys.sorted().joined(separator: ","))")
        return false
    }
    report("APPKIT_DEFAULTS persistent=empty")
    return true
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("AppKit test host: \(message)\n".utf8))
    exit(1)
}

// MARK: - AppKitTestHostDelegate

@MainActor
private final class AppKitTestHostDelegate: NSObject, NSApplicationDelegate {
    private var fixtureWindow: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let arguments = CommandLine.arguments
        if arguments.count == 2, arguments[1] == "--activation-self-test" {
            runActivationSelfTest()
            return
        }
        if arguments.count == 2, arguments[1] == "--exception-self-test" {
            runExceptionSelfTest()
            return
        }
        guard arguments.count == 5 else {
            fail("expected bundle, Testing image, filter and event path")
        }
        guard dlopen(arguments[1], RTLD_NOW | RTLD_LOCAL) != nil else {
            fail(String(cString: dlerror()))
        }
        let testingImages = (0 ..< _dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            let path = String(cString: name)
            return path.contains("/Testing.framework/") ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : nil
        }
        guard testingImages.count == 1,
              testingImages[0] == URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath().path
        else {
            fail("unexpected Testing images: \(testingImages)")
        }
        Task { @MainActor in
            var options = Testing.__CommandLineArguments_v0()
            options.parallel = false
            options.filter = [arguments[3]]
            options.eventStreamOutputPath = arguments[4]
            options.eventStreamSchemaVersion = "6.3.0"
            let code: CInt = await Testing.__swiftPMEntryPoint(passing: options)
            // After the entry point returns, on passing and failing runs alike: a leftover setting
            // fails the run even when every test passed.
            let defaultsClean = verifyHostDefaultsAtExit()
            fflush(nil)
            exit(code != 0 ? code : (defaultsClean ? 0 : 1))
        }
    }

    func applicationShouldSaveSecureApplicationState(_: NSApplication) -> Bool { false }

    func applicationShouldRestoreSecureApplicationState(_: NSApplication) -> Bool { false }

    private func runActivationSelfTest() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isRestorable = false
        fixtureWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !(NSApp.isActive && window.isKeyWindow) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            print("APPKIT_ACTIVATION active=\(NSApp.isActive) key=\(window.isKeyWindow)")
            let activated = NSApp.isActive && window.isKeyWindow
            let defaultsClean = verifyHostDefaultsAtExit()
            fflush(nil)
            exit(activated && defaultsClean ? 0 : 1)
        }
    }

    /// An ObjC exception raised inside a main-actor Task must terminate the host abnormally
    /// with the post-raise identity on stderr — and with no crash dialog. The system crash
    /// reporter raises its "quit unexpectedly" dialog (owned by UserNotificationCenter) for an
    /// app that owned the foreground, and while that dialog is up it owns the foreground, so
    /// every later hosted test fails its key-and-active precondition (the run 4-6 harness
    /// failure). Dropping to the prohibited activation policy first means the app never owned
    /// the foreground, so no dialog is raised; the crash log is still written and the process
    /// still dies by the same trap.
    ///
    /// The registered `NSApplicationCrashOnExceptions` default makes the event loop's exception
    /// handler terminate through a trap instead of swallowing the raise and corrupting the
    /// Swift Testing executor state (the #45 host crash signature) — and because the trap
    /// bypasses the uncaught-exception handler, the bounded signal handler installed here
    /// prints the identity line itself. The pre-raise breadcrumb deliberately carries no
    /// reason: only the post-raise `APPKIT_EXCEPTION` line (uncaught handler or signal
    /// handler) or AppKit's terminating text proves the exception actually unwound. The
    /// watchdog uses a distinct exit code (3) so a swallowed exception can never masquerade
    /// as a crash.
    private func runExceptionSelfTest() {
        let reason = "AppKitTestHost exception self-test"
        NSApp.setActivationPolicy(.prohibited)
        for signalNumber in [SIGTRAP, SIGILL, SIGABRT, SIGBUS] {
            signal(signalNumber, exceptionSelfTestTerminationHandler)
        }
        NSSetUncaughtExceptionHandler { exception in
            FileHandle.standardError.write(Data(
                "APPKIT_EXCEPTION name=\(exception.name.rawValue) reason=\(exception.reason ?? "")\n".utf8
            ))
            fflush(nil)
        }
        FileHandle.standardError.write(Data("APPKIT_EXCEPTION_RAISING\n".utf8))
        fflush(nil)
        Task { @MainActor in
            exceptionSelfTestDeliberatelyRaised = 1
            NSException(name: NSExceptionName.invalidArgumentException, reason: reason).raise()
        }
        Task { @MainActor in
            // The raise must terminate the process; a swallowed exception fails deterministically.
            try? await Task.sleep(for: .seconds(10))
            FileHandle.standardError.write(Data("AppKit test host: exception self-test did not terminate\n".utf8))
            fflush(nil)
            exit(3)
        }
    }
}

// MARK: - AppKitTestHost

@main
private struct AppKitTestHost {
    @MainActor
    static func main() {
        // Registered before NSApplication.shared: any ObjC exception the event loop catches in
        // a hosted test terminates the process immediately with its own backtrace instead of
        // corrupting the async executor state and crashing later elsewhere.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        applyHostDefaultsOverrides()
        if let problem = effectiveDefaultsProblem() {
            fail("effective defaults differ from the host overrides: \(problem)")
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppKitTestHostDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
