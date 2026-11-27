import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - LayerMotionLookHostedTests + outline and shimmer clip

/// The running workflow outline against its former AngularGradient body, and the shimmer's rounded clip. An extension,
/// so the tests stay in the serialized suite.
extension LayerMotionLookHostedTests {

    // MARK: Running workflow outline

    /// The former `WorkflowRunningOutline` body at a frozen phase, around a node of `size`, with the layer view's overhang as
    /// padding so no ink is cut by the hosting view.
    private func outlineReference(isSelected: Bool, phase: Double, size: CGSize) -> some View {
        let gradient = AngularGradient(
            colors: [.accentLink.opacity(0.15), .accentLink.opacity(0.15), .accentLink, .accentLink.opacity(0.15)],
            center: .center, startAngle: .degrees(phase * 360), endAngle: .degrees(phase * 360 + 360)
        )
        return Group {
            if isSelected {
                RoundedRectangle(cornerRadius: HfRadius.card)
                    .stroke(gradient, lineWidth: HfRadius.Metrics.workflowNodeRingWidth)
                    .padding(-HfRadius.Metrics.workflowNodeRingInset)
            } else {
                RoundedRectangle(cornerRadius: HfRadius.card).strokeBorder(gradient, lineWidth: 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(LayerOutlineView.overhang)
    }

    @Test(arguments: [true, false])
    func givenRunningOutline_whenFrozenAtPhases_thenItMatchesTheFormerAngularGradientBody(isSelected: Bool) async throws {
        let node = CGSize(width: 160, height: 80)
        for appearance in Self.appearances {
            // given
            let fixture = LayerMotionFixture(appearance: appearance)
            defer { fixture.close() }
            for phase in [0.0, 0.25] {
                // when — `candidate` offsets the view by `pad`, so the reference carries the same padding
                let expected = try #require(await reference(outlineReference(isSelected: isSelected, phase: phase, size: node)
                    .padding(Self.pad), in: fixture))
                let view = LayerOutlineView(isSelected: isSelected)
                view.frame = CGRect(origin: .zero, size: CGSize(width: node.width + 2 * LayerOutlineView.overhang,
                                                                 height: node.height + 2 * LayerOutlineView.overhang))
                let rendered = try #require(await candidate(view, size: expected.size, in: fixture) {
                    LayerMotion.withoutActions { view.turningLayer.transform = CATransform3DMakeRotation(phase * 2 * .pi, 0, 0, 1) }
                })

                // then — same ink bounds, and the gradient's angle and direction agree (the mean difference would
                // be large if the conic started at another angle or ran the other way)
                let label = "outline_\(isSelected)_\(name(appearance))_\(phase)"
                report(label, expected.bitmap, rendered)
                expectSameBounds(expected.bitmap, rendered, label)
                let difference = expected.bitmap.meanDifference(from: rendered, inside: expected.bitmap.inkBounds())
                #expect(difference <= 3, "\(label) mean difference over the ink bounds")
                if phase == 0 {
                    // negative control: a reference a half turn on must not pass, or the threshold proves nothing
                    let wrong = try #require(await reference(outlineReference(isSelected: isSelected, phase: 0.5, size: node)
                        .padding(Self.pad), in: fixture))
                    #expect(wrong.bitmap.meanDifference(from: rendered, inside: wrong.bitmap.inkBounds()) > 3, "\(label) control")
                }
            }
        }
    }

    @Test func givenSelectedRunningOutline_whenHostedInSwiftUI_thenInkReachesPastTheNodeFrame() async throws {
        // given
        let fixture = LayerMotionFixture()
        defer { fixture.close() }
        let node = CGSize(width: 160, height: 80)
        let margin: CGFloat = 20
        let container = NSView(frame: CGRect(x: 0, y: 0, width: node.width + 2 * margin, height: node.height + 2 * margin))
        container.wantsLayer = true
        fixture.container.addSubview(container)
        defer { container.removeFromSuperview() }
        let host = NSHostingView(rootView: AnyView(WorkflowRunningOutline(isSelected: true)
            .frame(width: node.width, height: node.height)
            .padding(margin)
            .environment(\.hfReduceMotionOverride, true)))
        host.frame = container.bounds
        container.addSubview(host)

        // when
        var bitmap: LayerMotionBitmap?
        await waitUntil {
            bitmap = LayerMotionRender.layerTree(of: container)
            return bitmap?.inkBounds() != nil
        }

        // then — the 4 pt ring sits 2 pt outside the node's frame, so ink starts before the frame's edge
        let ink = try #require(bitmap?.inkBounds())
        #expect(ink.minX < margin - 1 && ink.minY < margin - 1, "ink \(ink) must reach outside the node frame at \(margin)")
        #expect(ink.maxX > margin + node.width + 1 && ink.maxY > margin + node.height + 1, "ink \(ink)")
    }

    // MARK: Shimmer clip

    @Test func givenRoundedSkeletonUnderReduceMotion_whenLayerTreeIsRendered_thenPulseLayerIsClippedToTheRoundedShape() async throws {
        for appearance in Self.appearances {
            // given
            let fixture = LayerMotionFixture(appearance: appearance)
            defer { fixture.close() }
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
            container.wantsLayer = true
            fixture.container.addSubview(container)
            defer { container.removeFromSuperview() }
            let host = NSHostingView(rootView: AnyView(SkeletonBlock(width: 20, height: 20, cornerRadius: 10)
                .environment(\.shimmerReduceMotionOverride, true)))
            host.frame = container.bounds
            container.addSubview(host)

            // when
            var bitmap: LayerMotionBitmap?
            await waitUntil {
                bitmap = LayerMotionRender.layerTree(of: container)
                return bitmap?.inkBounds() != nil
            }

            // then — transparent corners, a skeletonFill centre
            let rendered = try #require(bitmap)
            let corner = Int(1 * rendered.scale / 2)
            #expect(rendered.alpha(x: corner, y: corner) < 0.01, "\(name(appearance)) top left corner must be transparent")
            #expect(rendered.alpha(x: rendered.width - 1 - corner, y: rendered.height - 1 - corner) < 0.01, "\(name(appearance)) bottom right corner")
            let expected = resolved(Color.skeletonFill, appearance)
            let centre = try #require(rendered.strongestInkColor(in: CGRect(x: 8, y: 8, width: 4, height: 4)))
            #expect(abs(centre.alpha - expected.alpha) * 255 <= Tolerance.color, "\(name(appearance)) centre alpha \(centre.alpha) vs \(expected.alpha)")
            #expect(levels((centre.red, centre.green, centre.blue, 1), (expected.red, expected.green, expected.blue, 1)) <= Tolerance.color)
        }
    }
}
