import CoreGraphics
import HfUI
import Testing

// MARK: - TypeScaleTests

@Suite struct TypeScaleTests {

    @Test func givenEachTextStyle_whenAskedForItsPointSize_thenPinsTheNativeMacSize() {
        let expected: [(style: HfTextStyle, size: CGFloat)] = [
            (.setupEyebrow, 9), (.setupFootnote, 10), (.caption, 11), (.secondary, 12), (.body, 13), (.reading, 14),
            (.headline, 15), (.title, 18), (.setupWelcomeTitle, 20), (.hero, 22)
        ]
        for (style, size) in expected {
            // given
            let typeScaleStyle = style

            // when
            let pointSize = typeScaleStyle.pointSize

            // then
            #expect(pointSize == size, "\(style) pins \(size) pt")
        }
    }

    @Test func givenTheTypeScale_whenIteratedInCaseIterableOrder_thenSizesStrictlyIncrease() {
        // given
        let styles = HfTextStyle.allCases

        // when
        let sizes = styles.map(\.pointSize)

        // then
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { earlier, later in earlier < later },
                "\(sizes) is not strictly increasing")
    }
}
