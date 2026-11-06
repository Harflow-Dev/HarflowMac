import AppKit
import Darwin
import Foundation
import HfTestUtilities
import Testing

// MARK: - WorkflowFailedLayoutEvidence

/// Failure-only evidence; the caller retains the original comparison operands and assertion.
@MainActor enum WorkflowFailedLayoutEvidence {
    static func record(fixture: RedesignHost, operands: [String: Any], checkpoint: [String: Any],
                       directory: () throws -> URL?, geometry: () throws -> [String: Any]) async {
        var report: [String: Any] = [
            "originalOperands": operands, "originalValidation": checkpoint,
            "elapsedTimeOrigin": "VM creation in the original test",
            "chronology": "Original operands/validation; native geometry; owned window image; host bitmap; post-capture geometry. " +
                "Images follow failed operands. Window capture pumps the runloop; host bitmap explicitly forces layout/display."
        ]
        do {
            guard let directory = try directory() else { return }
            let name = "failed-editor-" + UUID().uuidString
            let json = directory.appendingPathComponent(name + ".json")
            try write(report, to: json)
            report["beforeWindowCapture"] = try geometry()
            report["windowBeforeCapture"] = metadata(fixture.window)
            try write(report, to: json)
            do {
                try await captureWindow(fixture.window, to: directory.appendingPathComponent(name + "-window.png"))
            } catch { report["windowCaptureError"] = String(describing: error); Issue.record(error) }
            report["windowAfterCapture"] = metadata(fixture.window)
            report["afterWindowCapture"] = try geometry()
            try write(report, to: json)
            do {
                report["hostBitmap"] = try captureHost(fixture.host, to: directory.appendingPathComponent(name + "-host.png"))
            } catch { report["hostCaptureError"] = String(describing: error); Issue.record(error) }
            report["afterHostCapture"] = try geometry()
            report["windowAfterHostCapture"] = metadata(fixture.window)
            try write(report, to: json)
        } catch { Issue.record(error) }
    }

    private static func metadata(_ window: NSWindow) -> [String: Any] {
        ["uptime": ProcessInfo.processInfo.systemUptime, "windowNumber": window.windowNumber,
         "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow,
         "applicationActive": NSApp.isActive, "windowFrame": NSStringFromRect(window.frame),
         "contentLayoutRect": NSStringFromRect(window.contentLayoutRect), "backingScaleFactor": window.backingScaleFactor]
    }

    private static func captureWindow(_ window: NSWindow, to url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        let log = url.deletingPathExtension().appendingPathExtension("log")
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
        if process.isRunning {
            // This PID belongs to the child created above; escalation never targets another app.
            let result = kill(process.processIdentifier, SIGKILL)
            guard result == 0 || errno == ESRCH else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            await waitUntil(timeout: 2) { !process.isRunning }
        }
        guard !process.isRunning, process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "WorkflowScreenLayoutDiagnostic", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Owned window capture failed or exceeded its bound; inspect \(log.path)"])
        }
    }

    private static func captureHost(_ view: NSView, to url: URL) throws -> [String: Any] {
        let before = view.bounds
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "WorkflowScreenLayoutDiagnostic", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate hosted-view bitmap"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WorkflowScreenLayoutDiagnostic", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode hosted-view bitmap"])
        }
        try data.write(to: url, options: .atomic)
        return ["pixelsWide": bitmap.pixelsWide, "pixelsHigh": bitmap.pixelsHigh,
                "boundsBeforeForcedLayout": NSStringFromRect(before), "capturedBounds": NSStringFromRect(view.bounds),
                "hostIsFlipped": view.isFlipped, "limitation": "Hosted-view cacheDisplay may differ from native window composition."]
    }

    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

extension RedesignHost {
    /// Whether any accessibility element's label, title or value contains `text`.
    func hasElement(containing text: String) -> Bool {
        descendants.flatMap { elements(in: $0) }.contains { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { string(object, $0)?.contains(text) == true }
        }
    }
}
