import AppKit
import Foundation
import HfTestUtilities
import SwiftUI
import Testing

@MainActor
final class ObservationHost {
    let controller: NSHostingController<AnyView>
    let host: NSView
    let window: NSWindow
    private let requestedSize: NSSize
    private let previousEnhancedInterface: Any?
    private let previousActivationPolicy: NSApplication.ActivationPolicy
    private var previousCaptureSignature: [UInt8]?

    init(_ view: some View, width: Double, height: Double, appearance: ColorScheme? = nil) {
        _ = NSApplication.shared
        self.requestedSize = NSSize(width: width, height: height)
        self.previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        self.previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let controller = NSHostingController(rootView: AnyView(view.frame(width: width, height: height)))
        controller.sceneBridgingOptions = .all
        controller.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        self.controller = controller
        self.host = controller.view
        self.window = window
        if let appearance { window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) }
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentViewController = nil
        window.close()
        NSApplication.shared.accessibilitySetValue(previousEnhancedInterface,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.setActivationPolicy(previousActivationPolicy)
    }

    func requireForeground() async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await waitUntil { self.window.isKeyWindow && NSApp.isActive }
        try #require(window.isKeyWindow && NSApp.isActive, "Native focus assertions require an active key fixture window")
    }

    func requireRequestedBounds() throws {
        host.layoutSubtreeIfNeeded()
        let actual = host.bounds.size
        try #require(abs(actual.width - requestedSize.width) <= 1 && abs(actual.height - requestedSize.height) <= 1,
            Comment(rawValue: "Fixture root must retain requested viewport: requested=\(requestedSize), actual=\(actual)"))
    }

    func find(_ text: String) -> NSObject? {
        let matches = objects().filter { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { string(object, $0) == text }
        }
        return matches.first { object in
            let role = string(object, "accessibilityRole")
            return role == NSAccessibility.Role.button.rawValue || role == NSAccessibility.Role.disclosureTriangle.rawValue
        } ?? matches.first
    }

    func objects() -> [NSObject] {
        host.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            let selector = NSSelectorFromString("accessibilityChildren")
            let children = element.responds(to: selector)
                ? element.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
            return [element] + children.compactMap { $0 as? NSObject }.flatMap(walk) + ((element as? NSView)?.subviews ?? []).flatMap(walk)
        }
        return walk(host)
    }

    func string(_ object: NSObject, _ name: String) -> String? {
        if let accessible = object as? any NSAccessibilityProtocol {
            switch name {
            case "accessibilityLabel": return accessible.accessibilityLabel()
            case "accessibilityTitle": return accessible.accessibilityTitle()
            case "accessibilityValue": return accessible.accessibilityValue() as? String
            case "accessibilityRole": return accessible.accessibilityRole()?.rawValue
            default: break
            }
        }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    func press(_ object: NSObject) -> Bool {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Press.self)
        return implementation(object, selector)
    }

    func frame(_ object: NSObject) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol { return window.convertFromScreen(accessible.accessibilityFrame()) }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return window.convertFromScreen(value.rectValue)
    }

    func isFocused(_ object: NSObject) -> Bool? {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.isAccessibilityFocused() }
        let selector = NSSelectorFromString("isAccessibilityFocused")
        guard object.responds(to: selector) else { return nil }
        typealias ReadFocused = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: ReadFocused.self)
        return implementation(object, selector)
    }

    func captureIfRequested(name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_OBSERVATION_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let roots = [URL(fileURLWithPath: "/private/tmp", isDirectory: true), FileManager.default.temporaryDirectory]
            .map(canonicalComponents)
        func isTemporary(_ candidate: URL) -> Bool {
            let components = canonicalComponents(candidate)
            return roots.contains { root in components.count > root.count && components.starts(with: root) }
        }
        #expect(isTemporary(directory), "opt-in screenshots must remain in a temporary directory")
        guard isTemporary(directory) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(isTemporary(directory), "created capture directory must not escape temporary roots through a symlink")
        guard isTemporary(directory) else { return }
        await waitUntil { self.hasStableRenderedFrame }
        #expect(hasStableRenderedFrame, "a capture must contain stable rendered content")
        try requireRequestedBounds()
        let bitmap = try renderedBitmap()
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Resolve the nearest existing ancestor before appending a not-yet-created suffix.
    /// This keeps temporary aliases canonical even when Foundation cannot resolve the final directory yet.
    private func canonicalComponents(_ url: URL) -> [String] {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { break }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        return ancestor.resolvingSymlinksInPath().standardizedFileURL.pathComponents + suffix
    }

    func focusDiagnostics(expectedText: String) -> String {
        let values = objects()
.filter { isFocused($0) == true || string($0, "accessibilityValue") == expectedText
            || string($0, "accessibilityLabel") == expectedText
        }
            .map { object in
                "\(String(describing: type(of: object))) role=\(string(object, "accessibilityRole") ?? "nil") "
                    + "label=\(string(object, "accessibilityLabel") ?? "nil") value=\(string(object, "accessibilityValue") ?? "nil") "
                    + "focused=\(String(describing: isFocused(object)))"
            }
.joined(separator: "; ")
        return "key=\(window.isKeyWindow) active=\(NSApp.isActive) responder=\(String(describing: window.firstResponder)); \(values)"
    }

    private var hasStableRenderedFrame: Bool {
        guard let bitmap = try? renderedBitmap(), let first = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return false }
        var signature: [UInt8] = []
        var hasInk = false
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                hasInk = hasInk || abs(color.redComponent - first.redComponent)
                    + abs(color.greenComponent - first.greenComponent) + abs(color.blueComponent - first.blueComponent) > 0.75
                for channel in [color.redComponent, color.greenComponent, color.blueComponent] {
                    signature.append(UInt8(max(0, min(255, Int(channel * 255)))))
                }
            }
        }
        defer { previousCaptureSignature = signature }
        guard hasInk, let previous = previousCaptureSignature, previous.count == signature.count else { return false }
        return zip(previous, signature).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
    }

    private func renderedBitmap() throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let captured = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: captured)
        let content = try #require(captured.cgImage)
        let width = captured.pixelsWide
        let height = captured.pixelsHigh
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(content, in: CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = host.bounds.size
        return bitmap
    }

}
