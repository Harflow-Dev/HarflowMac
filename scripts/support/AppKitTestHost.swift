import AppKit
import Darwin
import Testing

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
            fflush(nil)
            exit(code)
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
            fflush(nil)
            exit(NSApp.isActive && window.isKeyWindow ? 0 : 1)
        }
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("AppKit test host: \(message)\n".utf8))
        exit(1)
    }
}

// MARK: - AppKitTestHost

@main
private struct AppKitTestHost {
    @MainActor
    static func main() {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppKitTestHostDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
