import AppKit
import Foundation

// MARK: - CenteredComposerEvidence

/// Shared hosted-evidence helpers for the centered-composer suite: guarded native AX probes
/// and the bounded options-popover locator diagnostics. The small pure walkers (tree,
/// descendants) live here in internal form so the suite and these helpers share one
/// implementation without exposing any hosted fixture type.
@MainActor
enum CenteredComposerEvidence {
    /// The exact native AX placeholder attribute, read through a guarded selector.
    static func accessibilityPlaceholder(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityPlaceholderValue")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    static func accessibilityFrame(of object: NSObject) -> NSRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }

    static func hasIdentifier(_ object: NSObject, _ identifier: String) -> Bool {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        return object.responds(to: selector)
            && object.perform(selector)?.takeUnretainedValue() as? String == identifier
    }

    /// A guarded string-attribute probe through the selector ABI: nothing is invented and
    /// absent selectors read as `nil`.
    static func axText(of object: NSObject, _ attribute: String) -> String? {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The exact owned inner options scroll view: the native `NSScrollView` descended from the
    /// popup's own content that scrolls the mounted option fields. The stable identifier
    /// production puts on the SwiftUI options scroll view cross-qualifies it when the host
    /// forwards it to the native view; the containing-scroll relationship is the semantic
    /// anchor either way. No popover chrome measurement stands in.
    static func optionsScrollView(containing field: NSTextField, in popup: NSWindow) -> NSScrollView? {
        guard let content = popup.contentView else { return nil }
        let candidates = descendants(content).compactMap { $0 as? NSScrollView }
        let identified = candidates.filter { hasIdentifier($0, "new-session-options-scroll") }
        if identified.count == 1 { return identified.first }
        return candidates.first { descendants($0).contains { $0 === field } }
    }

    /// Always-on evidence for the options popover, written whenever the capture directory is
    /// set — pass or fail: the owned native view hierarchy, the mounted field's ancestor chain,
    /// the popup's AX tree, and every scroll-view/identifier locator identity with its bounds
    /// and frames, including the chosen locator's mismatch against the intended inner
    /// 360 x expectedHeight surface. The caller asserts that surface unchanged; this dump is
    /// proof the actual hierarchy adjudicates on — never a chrome subtraction or a re-derived
    /// inner locator.
    static func captureOptionsEvidence(
        popup: NSWindow, width: Int, height: Int, expectedHeight: CGFloat, effort: NSTextField
    ) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_COMPOSER_CAPTURE_DIR"], !output.isEmpty else { return }
        let content = popup.contentView
        let payload: [String: Any] = [
            "expectedInnerWidth": 360,
            "expectedInnerHeight": NSNumber(value: Double(expectedHeight)),
            "viewport": "\(width)x\(height)",
            "popupFrame": NSStringFromRect(popup.frame),
            "contentBounds": content.map { NSStringFromRect($0.bounds) } ?? "none",
            "nativeHierarchy": optionsNativeHierarchy(of: content),
            "effortAncestry": optionsEffortAncestry(of: effort),
            "axTree": optionsAxTree(of: popup),
            "scrollCandidates": optionsScrollCandidates(of: popup, effort: effort),
            "axIdentifierNodes": optionsAxIdentifierNodes(of: popup),
            "locator": optionsLocatorSummary(of: popup, expectedHeight: expectedHeight, effort: effort)
        ] as [String: Any]
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("options-evidence-\(width)x\(height).json"))
    }

    /// The owned popup content's native descendant dump: bounded depth and node count.
    private static func optionsNativeHierarchy(of content: NSView?) -> [[String: Any]] {
        var hierarchy: [[String: Any]] = []
        guard let content else { return hierarchy }
        func describe(_ view: NSView, depth: Int) {
            guard hierarchy.count < 128, depth <= 12 else { return }
            hierarchy.append([
                "depth": depth,
                "type": String(describing: type(of: view)),
                "frame": NSStringFromRect(view.frame),
                "bounds": NSStringFromRect(view.bounds)
            ] as [String: Any])
            for subview in view.subviews { describe(subview, depth: depth + 1) }
        }
        describe(content, depth: 0)
        return hierarchy
    }

    /// The mounted option field's own superview chain, bounded in depth.
    private static func optionsEffortAncestry(of effort: NSTextField) -> [[String: Any]] {
        var ancestry: [[String: Any]] = []
        var ancestor: NSView? = effort
        while let view = ancestor, ancestry.count < 12 {
            ancestry.append([
                "type": String(describing: type(of: view)),
                "frame": NSStringFromRect(view.frame),
                "bounds": NSStringFromRect(view.bounds)
            ] as [String: Any])
            ancestor = view.superview
        }
        return ancestry
    }

    /// The popup's AX tree nodes with role, label, identifier and frame when published.
    private static func optionsAxTree(of popup: NSWindow) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        for object in tree(popup).prefix(256) {
            var node: [String: Any] = [
                "type": String(describing: type(of: object)),
                "role": axText(of: object, "accessibilityRole") ?? "none",
                "label": axText(of: object, "accessibilityLabel") ?? "none"
            ]
            if let identifier = axText(of: object, "accessibilityIdentifier") { node["identifier"] = identifier }
            if let frame = accessibilityFrame(of: object) { node["frame"] = NSStringFromRect(frame) }
            nodes.append(node)
            if nodes.count >= 64 { break }
        }
        return nodes
    }

    /// Every native scroll-view candidate descended from the popup's own content, with its
    /// bounds, frame and whether it actually scrolls the mounted effort field.
    private static func optionsScrollCandidates(of popup: NSWindow, effort: NSTextField) -> [[String: Any]] {
        var candidates: [[String: Any]] = []
        guard let content = popup.contentView else { return candidates }
        for view in descendants(content).compactMap({ $0 as? NSScrollView }).prefix(8) {
            candidates.append([
                "type": String(describing: type(of: view)),
                "bounds": NSStringFromRect(view.bounds),
                "frameInContent": NSStringFromRect(view.convert(view.bounds, to: content)),
                "containsEffortField": descendants(view).contains { $0 === effort },
                "identifier": hasIdentifier(view, "new-session-options-scroll") ? "new-session-options-scroll" : "none"
            ] as [String: Any])
        }
        return candidates
    }

    /// The AX nodes carrying the stable options identifier, with their frames.
    private static func optionsAxIdentifierNodes(of popup: NSWindow) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        for object in tree(popup).prefix(256)
        where axText(of: object, "accessibilityIdentifier") == "new-session-options-scroll" {
            nodes.append([
                "type": String(describing: type(of: object)),
                "frame": accessibilityFrame(of: object).map { NSStringFromRect($0) } ?? "none"
            ] as [String: Any])
            if nodes.count >= 8 { break }
        }
        return nodes
    }

    /// The chosen locator's raw identities and bounds with their mismatch deltas against the
    /// intended inner 360 x expectedHeight surface.
    private static func optionsLocatorSummary(
        of popup: NSWindow, expectedHeight: CGFloat, effort: NSTextField
    ) -> [String: Any] {
        var locator: [String: Any] = [
            "nativeScrollView": "none",
            "axIdentifierFrame": "none"
        ]
        if let scroll = optionsScrollView(containing: effort, in: popup) {
            locator["nativeScrollView"] = String(describing: type(of: scroll))
            locator["nativeScrollBounds"] = NSStringFromRect(scroll.bounds)
            locator["nativeScrollWidthDelta"] = NSNumber(value: Double(scroll.bounds.width - 360))
            locator["nativeScrollHeightDelta"] = NSNumber(value: Double(scroll.bounds.height - expectedHeight))
        }
        if let axScroll = tree(popup).first(where: { hasIdentifier($0, "new-session-options-scroll") }),
           let frame = accessibilityFrame(of: axScroll) {
            locator["axIdentifierFrame"] = NSStringFromRect(frame)
            locator["axWidthDelta"] = NSNumber(value: Double(frame.width - 360))
            locator["axHeightDelta"] = NSNumber(value: Double(frame.height - expectedHeight))
        }
        return locator
    }

    // MARK: Shared small walkers

    static func tree(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var result = [object]
            if let window = object as? NSWindow, let content = window.contentView { result += collect(content) }
            if let view = object as? NSView { result += view.subviews.flatMap(collect) }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector),
               let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                result += children.flatMap(collect)
            }
            return result
        }
        return collect(root)
    }

    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
