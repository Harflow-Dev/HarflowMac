import AppKit
@testable import PbUI
import SwiftUI
import Testing

// MARK: - SkeletonColorTests

@Suite struct SkeletonColorTests {

    private func rgba(_ color: Color, in appearance: NSAppearance.Name) -> (white: CGFloat, alpha: CGFloat) {
        var result: (CGFloat, CGFloat) = (0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.genericGray)!
            result = (resolved.whiteComponent, resolved.alphaComponent)
        }
        return result
    }

    @Test func givenTheSkeletonFill_whenResolvedInEachMode_thenItIsBlackSixPercentInLightAndWhiteSevenInDark() {
        // given / when
        let light = rgba(.skeletonFill, in: .aqua)
        let dark = rgba(.skeletonFill, in: .darkAqua)

        // then
        #expect(light.white < 0.01 && abs(light.alpha - 0.06) < 0.005)
        #expect(dark.white > 0.99 && abs(dark.alpha - 0.07) < 0.005)
    }

    @Test func givenTheSheen_whenResolvedInEachMode_thenItIsAStrongWhiteInLightAndAFaintOneInDark() {
        // given / when
        let light = rgba(.skeletonSheen, in: .aqua)
        let dark = rgba(.skeletonSheen, in: .darkAqua)

        // then
        #expect(light.white > 0.99 && abs(light.alpha - 0.75) < 0.005)
        #expect(dark.white > 0.99 && abs(dark.alpha - 0.08) < 0.005)
    }
}
