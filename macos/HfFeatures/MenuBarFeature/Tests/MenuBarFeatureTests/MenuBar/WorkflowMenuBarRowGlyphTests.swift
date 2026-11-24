import AppKit
import HfTestUtilities
import HfUI
@testable import MenuBarFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowMenuBarRowGlyphTests

/// The menu bar's workflow rows draw the approved status glyphs (HarflowDesign `fe6428c`): the spinner while working, the
/// raised hand for attention, and a terminal status's own glyph (the workflow glyph when done). With
/// `HARFLOW_STATUS_GLYPH_CAPTURE_DIR` set the rows are also rendered to PNGs, light and dark.
@MainActor @Suite(.serialized) struct WorkflowMenuBarRowGlyphTests {
    private func row(_ status: String) throws -> WorkflowMenuBarRow {
        try #require(WorkflowMenuBarRow([
            "workflow_run_id": .string("run-\(status)"), "name": .string("Review \(status)"), "status": .string(status),
            "attention_reason": .string("Waiting for the operator")
        ]))
    }

    private func labels(_ view: some View) async -> [String] {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: view.environment(\.hfReduceMotionOverride, true).frame(width: 340))
        host.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func collect(_ element: NSObject, _ seen: inout Set<ObjectIdentifier>) -> [String] {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            var found: [String] = []
            if element.responds(to: NSSelectorFromString("accessibilityLabel")), let value = element.value(forKey: "accessibilityLabel") as? String {
                found.append(value)
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [NSObject] {
                for child in children { found += collect(child, &seen) }
            }
            if let node = element as? NSView { for sub in node.subviews { found += collect(sub, &seen) } }
            return found
        }
        var result: [String] = []
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            var seen = Set<ObjectIdentifier>()
            result = collect(host, &seen)
            return result.contains { $0.hasPrefix("Review") } || result.contains("Waiting for the operator")
        }
        return result
    }

    @Test(arguments: [
        ("needs_attention", "Needs you"), ("needs_input", "Needs you"), ("completed", "Done"),
        ("failed", "Failed"), ("cancelled", "Cancelled"), ("running", "Workflow run, running")
    ])
    func givenWorkflowRowStatus_whenHosted_thenItsLeadingIconCarriesTheApprovedLabel(status: String, expected: String) async throws {
        // given
        let view = WorkflowMenuBarRowView(model: try row(status), onTap: {})

        // when
        let strings = await labels(view)

        // then
        // the button combines its children, so the icon label leads the row's one spoken string
        #expect(strings.contains { $0.hasPrefix(expected + ", ") }, "\(status): \(strings)")
    }

    @Test func givenPausedWorkflowRow_whenHosted_thenItKeepsTheBranchSymbolWithNoStatusLabel() async throws {
        // given
        let view = WorkflowMenuBarRowView(model: try row("paused"), onTap: {})

        // when
        let strings = await labels(view)

        // then
        #expect(!strings.contains { $0.hasPrefix("Needs you") || $0.hasPrefix("Done") || $0.hasPrefix("Running") })
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenWorkflowRows_whenRenderedForReview_thenCapturesAreWrittenOnlyWhenRequested(scheme: ColorScheme) throws {
        // given
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_STATUS_GLYPH_CAPTURE_DIR"], !path.isEmpty else { return }
        let rows = try ["running", "needs_attention", "needs_input", "completed", "failed", "cancelled", "paused"].map(row)
        let surface = VStack(spacing: HfRadius.Metrics.spacing8) {
            ForEach(rows) { WorkflowMenuBarRowView(model: $0, onTap: {}) }
        }
        .padding(HfRadius.Metrics.spacing12)
        .frame(width: 380)
        .background(Color.windowBG)
        .environment(\.hfReduceMotionOverride, true)
        .environment(\.colorScheme, scheme)
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: surface)
            renderer.scale = 2
            image = renderer.cgImage
        }

        // when
        let bitmap = NSBitmapImageRep(cgImage: try #require(image))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("status-glyphs-menu-bar-workflow-rows-\(scheme == .light ? "light" : "dark").png"))

        // then
        #expect(bitmap.pixelsHigh > 0)
    }
}
