import AppKit
import Foundation
import HfTestUtilities
import Testing

// MARK: - M05MatrixCapture

/// Optional evidence for the M05 task-state matrix, written only when `HARFLOW_M05_MATRIX_CAPTURE_DIR` is set. Each state
/// produces a host bitmap, the exact owned window capture and a JSON describing the design route. These are evidence for
/// visual review, never pixel diffs.
@MainActor enum M05MatrixCapture {
    static let environmentKey = "HARFLOW_M05_MATRIX_CAPTURE_DIR"

    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The artifact name shared by the three outputs: `<suite>-<state>-<light|dark>-<W>x<H>`.
    static func name(suite: String, state: String, dark: Bool, size: NSSize) -> String {
        "\(suite)-\(state)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
    }

    // Writes the captures for one mounted state. Does nothing without the capture directory.
    // swiftlint:disable:next function_parameter_count
    static func record(suite: String, state: String, dark: Bool, size: NSSize, window: NSWindow, host: NSView) async throws {
        guard let directory else { return }
        let entry = M05StateTable.lookup(state)
        let name = name(suite: suite, state: state, dark: dark, size: size)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + "-host-bitmap.png"))
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
        var json: [String: Any] = [
            "state": state, "suite": suite, "designRoute": entry?.designRoute ?? "unknown",
            "designFile": entry?.designFile ?? "unknown", "designCommit": M05StateTable.designCommit,
            "size": "\(Int(size.width))x\(Int(size.height))", "appearance": dark ? "dark" : "light",
            "notRenderable": entry?.notRenderable ?? "", "captureMethod": "window-server exact owned window",
            "hostBitmap": name + "-host-bitmap.png"
        ]
        json["content"] = NSStringFromRect(host.bounds)
        json["outerWindow"] = NSStringFromRect(window.frame)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent(name + ".json"))
    }
}
