@testable import MainWindowFeature
@testable import MonitorCore
import Testing

/// F4-42: failures are listed with `dropFirst` when the task was not compared against the baseline
/// (the first failure is always the comparison failure itself, already surfaced by the banner).
@Suite struct ChangesPaneModelTests {
    
    @Test func givenComparedWithBase_whenListingFailures_thenEveryFailureShows() {
        // given
        let changes = GitChanges(
            files: [], diffs: [], commitsSinceBase: nil, branch: nil,
            labels: [], comparedWithBase: true,
            failures: [GitFailure(query: "diff", detail: "boom")]
        )
        
        // when
        let visible = ChangesPaneModel.visibleFailures(changes)
        
        // then
        #expect(visible.count == 1)
    }
    
    @Test func givenComparisonFailed_whenListingFailures_thenTheFirstIsDropped() {
        // given — the first failure is the comparison itself, already shown by the banner's own text.
        let changes = GitChanges(
            files: [], diffs: [], commitsSinceBase: nil, branch: nil,
            labels: [], comparedWithBase: false,
            failures: [GitFailure(query: "status", detail: "baseline unreadable"), GitFailure(query: "diff", detail: "boom")]
        )
        
        // when
        let visible = ChangesPaneModel.visibleFailures(changes)
        
        // then
        #expect(visible.count == 1)
        #expect(visible.first?.query == "diff")
    }
}
