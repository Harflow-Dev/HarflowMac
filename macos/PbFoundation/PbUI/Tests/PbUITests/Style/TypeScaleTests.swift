import CoreGraphics
import PbUI
import Testing

// MARK: - TypeScaleTests

@Suite struct TypeScaleTests {

    @Test func givenEachTextStyle_whenAskedForItsPointSize_thenPinsTheNativeMacSize() {
        let expected: [(style: PbTextStyle, size: CGFloat)] = [
            (.caption, 11), (.secondary, 12), (.body, 13), (.headline, 15), (.title, 18)
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
        let styles = PbTextStyle.allCases

        // when
        let sizes = styles.map(\.pointSize)

        // then
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { earlier, later in earlier < later },
                "\(sizes) is not strictly increasing")
    }
}
