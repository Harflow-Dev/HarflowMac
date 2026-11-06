import AppKit
import Foundation
import HfTestUtilities
import Testing

// MARK: - M04NativeWindowEvidence

/// Optional fixture evidence pinned to the exact owned native window; never launches an app.
@MainActor enum M04NativeWindowEvidence {
    static func record(window: NSWindow, name: String, directory: URL) async throws {
        try #require(NSApp.isActive && window.isVisible, "Native evidence requires an active fixture and visible owned window")
        if ProcessInfo.processInfo.environment["HARFLOW_M04_WINDOW_DIAGNOSTIC"] == "1", name == "shell-light-1280x800" {
            let root = try #require(window.contentView?.superview ?? window.contentView)
            let hierarchy = describe(root, depth: 0)
            try hierarchy.write(to: directory.appendingPathComponent(name + "-hierarchy.txt"), atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory.appendingPathComponent(name + ".png").path]
        let log = directory.appendingPathComponent(name + "-window-capture.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        await waitUntil(timeout: 5) { !process.isRunning }
        if process.isRunning {
            process.terminate()
            await waitUntil(timeout: 2) { !process.isRunning }
        }
        #expect(!process.isRunning, "The owned window capture must settle within its bound")
        guard !process.isRunning else { return }
        #expect(process.terminationStatus == 0, "Window capture failed; inspect \(log.path)")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".png").path))
    }

    private static func describe(_ view: NSView, depth: Int) -> String {
        let outline = (view as? NSOutlineView).map { " rows=\($0.numberOfRows) id=\($0.identifier?.rawValue ?? "none")" } ?? ""
        let prefix = String(repeating: "  ", count: depth)
        let line = "\(prefix)\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden)\(outline)\n"
        return line + view.subviews.map { describe($0, depth: depth + 1) }.joined()
    }
}
