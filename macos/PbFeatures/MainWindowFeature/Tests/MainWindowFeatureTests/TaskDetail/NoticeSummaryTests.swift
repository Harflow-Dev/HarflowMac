@testable import MainWindowFeature
import Testing

// MARK: - NoticeSummaryTests

@Suite struct NoticeSummaryTests {

    @Test func givenNoNotices_whenSummarised_thenThereIsNoHeaderLine() {
        // given / when / then
        #expect(NoticeSummary.text(count: 0) == nil)
    }

    @Test func givenOneNotice_whenSummarised_thenItIsSingular() {
        // given / when / then
        #expect(NoticeSummary.text(count: 1) == "1 notice")
    }

    @Test func givenSeveralNotices_whenSummarised_thenItIsPlural() {
        // given / when / then
        #expect(NoticeSummary.text(count: 3) == "3 notices")
    }

    @Test func givenRepeatedNotices_whenDeduplicated_thenEachAppearsOnceInFirstSeenOrder() {
        // given
        let notices = ["codex config warning", "branch notice", "codex config warning"]

        // when
        let distinct = InspectorModel.distinctNotices(notices)

        // then
        #expect(distinct == ["codex config warning", "branch notice"])
    }
}
