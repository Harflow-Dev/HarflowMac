@testable import HfRepository
import Testing

@Suite struct MissingFeatureTests {

    @Test func givenAFeaturePhrase_whenTheSentenceIsBuilt_thenItIsTheApprovedForm() {
        // given
        let canDo = "inspect the task store"

        // when
        let sentence = MissingFeature.sentence(canDo: canDo)

        // then
        #expect(sentence == "This Harflow runtime can't inspect the task store. Update Harflow to use it.")
    }
}
