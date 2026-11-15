import AppKit
import Foundation
import HfTestUtilities
import HfUI
import Testing

// MARK: - HostedCaptureEvidence

/// Optional review evidence for a hosted window, written only when the suite's own environment variable names a
/// directory. Each state produces a host bitmap, the exact owned window capture and a JSON naming the HarflowDesign
/// route, file and commit it was built against. Evidence for visual review, never a pixel diff.
@MainActor enum HostedCaptureEvidence {

    /// The design the captured state implements.
    struct Design {
        let route: String
        let file: String
        let commit: String
    }

    /// One captured state: which suite and state, in which appearance and size, against which design.
    struct Subject {
        let suite: String
        let state: String
        let dark: Bool
        let size: NSSize
        let design: Design
    }

    /// The directory named by `key`, or nil when capture is off.
    static func directory(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The artifact name shared by the three outputs: `<suite>-<state>-<light|dark>-<W>x<H>`.
    static func name(suite: String, state: String, dark: Bool, size: NSSize) -> String {
        "\(suite)-\(state)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
    }

    /// Writes the captures for one mounted state into `directory`.
    static func record(directory: URL, subject: Subject, window: NSWindow, host: NSView) async throws {
        let name = name(suite: subject.suite, state: subject.state, dark: subject.dark, size: subject.size)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + "-host-bitmap.png"))
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
        let json: [String: Any] = [
            "state": subject.state, "suite": subject.suite, "designRoute": subject.design.route, "designFile": subject.design.file,
            "designCommit": subject.design.commit, "size": "\(Int(subject.size.width))x\(Int(subject.size.height))",
            "appearance": subject.dark ? "dark" : "light", "captureMethod": "window-server exact owned window",
            "hostBitmap": name + "-host-bitmap.png", "content": NSStringFromRect(host.bounds),
            "outerWindow": NSStringFromRect(window.frame)
        ]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent(name + ".json"))
    }

    /// Makes the window's appearance Aqua or Dark Aqua and brings the application forward, so a capture never inherits the
    /// desktop's appearance and the window server has the window on screen.
    static func prepare(_ window: NSWindow, dark: Bool) async {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await waitUntil(timeout: 15) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            return NSApp.isActive && window.isKeyWindow
        }
        var passes = 0
        await waitUntil(timeout: 5) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= 40
        }
        await DisplayFrames.waitForPresentedFrame()
    }
}
