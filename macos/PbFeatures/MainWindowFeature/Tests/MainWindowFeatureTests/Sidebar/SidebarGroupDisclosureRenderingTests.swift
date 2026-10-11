import AppKit
@testable import MainWindowFeature
import PbUI
import SwiftUI
import Testing

// MARK: - SidebarGroupDisclosureRenderingTests

@MainActor @Suite(.serialized) struct SidebarGroupDisclosureRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func givenGroupDisclosure_whenRenderedWithSelectionProminence_thenItsActualGlyphUsesReadableInk(scheme: ColorScheme, expanded: Bool) throws {
        for emphasized in [false, true] {
            // given — the production glyph with exactly the environment a native selection supplies.
            let actual = SidebarGroupDisclosure(isExpanded: expanded, reduceMotion: true)
                .environment(\.backgroundProminence, emphasized ? .increased : .standard)
            let expected = reference(expanded: expanded, color: emphasized ? .onAccent : .secondaryText)

            // when
            let first = try render(actual, scheme: scheme, emphasized: emphasized)
            let repeated = try render(actual, scheme: scheme, emphasized: emphasized)
            let correct = try render(expected, scheme: scheme, emphasized: emphasized)

            // then — compare the actual painted glyph, including its rotation and unchanged frame.
            #expect(first == repeated)
            #expect(first == correct)
            if emphasized {
                let oldFixedInk = try render(reference(expanded: expanded, color: .secondaryText), scheme: scheme, emphasized: true)
                #expect(first != oldFixedInk, "The old fixed secondary ink must fail this emphasized selection regression")
            }
        }
    }

    private func reference(expanded: Bool, color: Color) -> some View {
        Image(systemName: "chevron.right")
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .font(.pb(.caption, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: PbRadius.Metrics.rowChevronFrame, height: PbRadius.Metrics.rowChevronFrame)
            .contentShape(Rectangle())
    }

    private func render(_ glyph: some View, scheme: ColorScheme, emphasized: Bool) throws -> Data {
        let fixture = glyph
            .padding(PbRadius.Metrics.spacing8)
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
        return try #require(NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:]))
    }
}
