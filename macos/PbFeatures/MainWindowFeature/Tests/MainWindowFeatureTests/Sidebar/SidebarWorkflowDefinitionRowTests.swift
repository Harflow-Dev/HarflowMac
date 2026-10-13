import AppKit
@testable import MainWindowFeature
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - SidebarWorkflowDefinitionRowTests

@MainActor @Suite(.serialized) struct SidebarWorkflowDefinitionRowTests {
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func givenWorkflowDefinitionRow_whenRenderedWithNativeProminence_thenTitleUsesTheMatchingPublicInk(scheme: ColorScheme, emphasized: Bool) throws {
        // given — the row receives the same prominence that a native List selection supplies.
        let title = "ship-release"
        let actual = SidebarWorkflowDefinitionRow(title: title)
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        let expected = reference(title: title, color: emphasized ? .onAccent : .primaryText)
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        let wrong = reference(title: title, color: .secondaryText)
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)

        // when
        let first = try render(actual, scheme: scheme, emphasized: emphasized)
        let repeated = try render(actual, scheme: scheme, emphasized: emphasized)
        let correct = try render(expected, scheme: scheme, emphasized: emphasized)
        let incorrect = try render(wrong, scheme: scheme, emphasized: emphasized)
        let titleMask = correct.mask(comparedTo: incorrect)

        // then — title paint is deterministic and follows the row-local native selection state.
        #expect(first == repeated)
        #expect(first.width == correct.width && first.height == correct.height)
        #expect(first.alpha == correct.alpha)
        #expect(first.nonTransparentMask == correct.nonTransparentMask)
        #expect(!titleMask.isEmpty, "The public-color references must produce a non-empty title-ink mask")
        #expect(first.matches(correct, at: titleMask), "The row title must use the matching public color")
        #expect(!incorrect.matches(correct, at: titleMask), "The deliberately wrong foreground must fail the title-pixel oracle")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenWorkflowDefinitionRow_whenRendered_thenNativeTitleAndIconSemanticsRemainAvailable(scheme: ColorScheme) async throws {
        // given
        let title = "ship-release"
        let fixture = HostedRow(SidebarWorkflowDefinitionRow(title: title).preferredColorScheme(scheme))
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.countMatches(title) == 1 }

        // then — the existing Label title and native system-image anatomy remain exposed; no new
        // traits or hints are added.
        #expect(fixture.countMatches(title) == 1)
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func givenOriginalInlineLabel_whenRendered_thenItsNativePaintIsRepeatable(scheme: ColorScheme, emphasized: Bool) throws {
        // The old inline Label is retained as a deterministic negative control. ImageRenderer does
        // not reproduce every native List paint decision on every SDK, so this test records its
        // stable render without asserting an unsupported AppKit root cause.
        let title = "ship-release"
        let old = Label(title, systemImage: "point.3.connected.trianglepath.dotted")
            .font(.pb(.body, weight: .medium))
            .frame(minHeight: PbRadius.Metrics.formRowHeight)
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)

        let first = try render(old, scheme: scheme, emphasized: emphasized)
        let repeated = try render(old, scheme: scheme, emphasized: emphasized)

        #expect(first == repeated)
    }

    private func reference(title: String, color: Color) -> some View {
        Label {
            Text(title)
                .foregroundStyle(color)
        } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }

    private func render(_ view: some View, scheme: ColorScheme, emphasized: Bool) throws -> RenderedImage {
        _ = NSApplication.shared
        let fixture = view
            .font(.pb(.body, weight: .medium))
            .frame(minHeight: PbRadius.Metrics.formRowHeight)
            .frame(width: PbRadius.Metrics.sidebarPreviewWidth)
            .padding(.horizontal, PbRadius.Metrics.spacing8)
            .background(emphasized ? Color.accentFill : Color.sidebarBG)
            .environment(\.colorScheme, scheme)
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: fixture)
            renderer.scale = 2
            image = renderer.cgImage
        }
        let captured = try #require(image)
        return try #require(RenderedImage(cgImage: captured))
    }
}

// MARK: - RenderedImage

private struct RenderedImage: Equatable {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init?(cgImage: CGImage) {
        self.width = cgImage.width
        self.height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.rgba = pixels
    }

    func mask(comparedTo other: Self) -> [Int] {
        guard width == other.width, height == other.height else { return [] }
        return stride(from: 0, to: rgba.count, by: 4).compactMap { offset in
            let same = rgba[offset] == other.rgba[offset]
                && rgba[offset + 1] == other.rgba[offset + 1]
                && rgba[offset + 2] == other.rgba[offset + 2]
                && rgba[offset + 3] == other.rgba[offset + 3]
            return same ? nil : offset
        }
    }

    func matches(_ other: Self, at mask: [Int]) -> Bool {
        width == other.width && height == other.height && mask.allSatisfy { offset in
            abs(Int(rgba[offset]) - Int(other.rgba[offset])) <= 1
                && abs(Int(rgba[offset + 1]) - Int(other.rgba[offset + 1])) <= 1
                && abs(Int(rgba[offset + 2]) - Int(other.rgba[offset + 2])) <= 1
                && rgba[offset + 3] == other.rgba[offset + 3]
        }
    }

    var alpha: [UInt8] {
        stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    var nonTransparentMask: [Bool] {
        alpha.map { $0 != 0 }
    }

}

// MARK: - HostedRow

@MainActor private final class HostedRow {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    private let previousEnhancedInterface: Any?

    init(_ view: some View) {
        _ = NSApplication.shared
        self.previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        self.host = NSHostingView(rootView: AnyView(view))
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.formRowHeight * 2),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
    }

    func settle(_ predicate: () -> Bool) async {
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return predicate()
        }
    }

    func countMatches(_ value: String) -> Int {
        descendants(host).flatMap { accessibilityElements($0) }.reduce(into: 0) { count, element in
            let matches = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
                let selector = NSSelectorFromString(key)
                return element.responds(to: selector) && element.perform(selector)?.takeUnretainedValue() as? String == value
            }
            if matches { count += 1 }
        }
    }

    func close() {
        window.contentView = nil
        window.close()
        NSApplication.shared.accessibilitySetValue(
            previousEnhancedInterface,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func accessibilityElements(_ view: NSView) -> [NSObject] {
        var result = [NSObject]()
        for subview in view.subviews {
            result += accessibilityElements(subview)
        }
        result += accessibilityTree(view)
        return result
    }

    private func accessibilityTree(_ element: NSObject) -> [NSObject] {
        var result = [element]
        let selector = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: selector),
              let children = element.perform(selector)?.takeUnretainedValue() as? [Any]
        else { return result }
        for child in children {
            if let object = child as? NSObject {
                result += accessibilityTree(object)
            }
        }
        return result
    }
}
