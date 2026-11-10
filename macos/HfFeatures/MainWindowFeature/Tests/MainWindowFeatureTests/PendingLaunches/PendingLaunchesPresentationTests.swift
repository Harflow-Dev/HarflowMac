import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct PendingLaunchesPresentationTests {
    private let rowA = PendingLaunchesFixture.item(id: "20261110-093000-a17c92")
    private let rowB = PendingLaunchesFixture.item(id: "20261110-093200-b28d03", state: "claimed",
                                                   title: "Prepare local environment", backend: "codex")

    private func make(_ inventory: PendingLaunchInventory, refused: Bool = false) -> PendingLaunchesPresentation {
        .make(.init(runtimeIdentity: UUID(), inventory: inventory), leaseRefused: refused)
    }

    // MARK: - States

    @Test func givenInitialSnapshot_whenMapped_thenLoadingWithoutAction() {
        // given / when
        let result = make(.init())
        // then
        #expect(result == .loading)
        #expect(result.checkAction == .hidden)
        #expect(result.rows.isEmpty)
    }

    @Test func givenCompletedCheckWithRows_whenMapped_thenInventoryWithCheckAgain() {
        // given / when
        let result = make(.init(rows: [rowA, rowB], completedCheck: true))
        // then
        #expect(result.kind == .inventory)
        #expect(result.title == "Pending launches")
        #expect(result.message == "Select a launch to check its status.")
        #expect(result.rows.map(\.id) == ["20261110-093000-a17c92", "20261110-093200-b28d03"])
        #expect(result.checkAction == .enabled)
    }

    @Test func givenCompletedCheckWithoutRows_whenMapped_thenEmptyWithoutAction() {
        // given / when
        let result = make(.init(completedCheck: true))
        // then
        #expect(result.kind == .empty)
        #expect(result.title == "No pending launches observed")
        #expect(result.message == "No pending launches were found in this completed check. New launches may appear after this check.")
        #expect(result.checkAction == .hidden)
    }

    @Test func givenEveryRefreshOnlyFailure_whenMapped_thenFailedCopy() {
        // given
        let failures: [PendingLaunchFailure] = [.unavailable, .capacity, .busy, .malformed, .superseded, .tool(.refused(code: "x", message: "y"))]
        for failure in failures {
            // when
            let result = make(.init(isStale: true, failure: failure))
            // then
            #expect(result.kind == .failed, "\(failure)")
            #expect(result.title == "Pending launches unavailable")
            #expect(result.message == "The engine could not be read. Pending launches may still exist.")
            #expect(result.checkAction == .enabled)
        }
    }

    @Test func givenCoverageFailures_whenMapped_thenIncompleteNeverFailedCopy() {
        // given
        for failure in [PendingLaunchFailure.incomplete, .requestBudget, .deadline] {
            // when
            let empty = make(.init(isStale: true, failure: failure))
            let withRows = make(.init(rows: [rowA], isStale: true, failure: failure))
            // then
            #expect(empty.kind == .incomplete)
            #expect(empty.title == "More launches may exist")
            #expect(empty.message == "This check could not cover every launch. More launches may exist.")
            #expect(empty.rows.isEmpty && empty.checkAction == .enabled)
            #expect(withRows.kind == .incomplete)
            #expect(withRows.rows.count == 1)
        }
    }

    // MARK: - Refresh, retention and refusal

    @Test func givenRefreshOverRows_whenMapped_thenRowsKeptAndCheckAgainDisabled() {
        // given / when
        let result = make(.init(rows: [rowA], isRefreshing: true, completedCheck: true))
        // then
        #expect(result.kind == .inventory)
        #expect(result.rows.count == 1)
        #expect(result.checkAction == .disabled)
    }

    @Test func givenRowsWithoutCompletedCheckOrRefresh_whenMapped_thenRowsWithEnabledCheckAgain() {
        // given / when
        let result = make(.init(rows: [rowA]))
        // then
        #expect(result.kind == .inventory)
        #expect(result.checkAction == .enabled)
    }

    @Test func givenRefreshWithoutRowsOrResult_whenMapped_thenStillLoading() {
        // given / when
        let result = make(.init(isRefreshing: true))
        // then
        #expect(result == .loading)
    }

    @Test func givenFailedRecheckThatRetainedRows_whenMapped_thenFailedCardAboveRetainedRows() {
        // given / when
        let result = make(.init(rows: [rowA, rowB], isStale: true, failure: .tool(.refused(code: "x", message: "y"))))
        // then
        #expect(result.kind == .failed)
        #expect(result.rows.count == 2)
        #expect(result.checkAction == .enabled)
    }

    @Test func givenLeaseRefusal_whenMapped_thenFailedOverInitialAndCachedCompletedSnapshots() {
        // given / when
        let initial = make(.init(), refused: true)
        let cachedComplete = make(.init(rows: [rowA], completedCheck: true), refused: true)
        let cachedEmpty = make(.init(completedCheck: true), refused: true)
        // then
        #expect(initial.kind == .failed && initial.rows.isEmpty)
        #expect(cachedComplete.kind == .failed && cachedComplete.rows.count == 1)
        #expect(cachedEmpty.kind == .failed)
        #expect(make(.init(), refused: false).kind == .loading)
    }

    @Test func givenOnlyLookupAndAttemptsDiffer_whenProjecting_thenProjectionIsEqual() {
        // given
        let identity = UUID()
        var first = PendingLaunchSnapshot(runtimeIdentity: identity, inventory: .init(rows: [rowA], completedCheck: true))
        var second = first
        first.lookups = []
        second.currentRuntime = nil
        second.attempts = []
        // when
        let changed = PendingLaunchSnapshot(runtimeIdentity: UUID(), inventory: first.inventory)
        // then
        #expect(PendingLaunchesProjection(first) == PendingLaunchesProjection(second))
        #expect(PendingLaunchesProjection(first) != PendingLaunchesProjection(changed))
    }

    // MARK: - Rows

    @Test(arguments: [
        ("waiting_for_resources", "Waiting for resources"), ("reserved", "Preparing"), ("claimed", "Preparing"),
        ("granted", "Launch granted"), ("not_started", "Did not start")
    ])
    func givenQualifiedState_whenMapped_thenDesignStateLabel(state: String, label: String) {
        // given / when
        let row = PendingLaunchesPresentation.row(PendingLaunchesFixture.item(id: "a1", state: state))
        // then
        #expect(row.meta == "Claude · Harflow · \(label)")
        #expect(row.title == "Review launch admission checks")
        #expect(row.id == "a1")
    }

    @Test func givenHarnessAndRepositoryPath_whenMapped_thenDisplayNameAndLastPathComponent() {
        // given / when
        let row = PendingLaunchesPresentation.row(PendingLaunchesFixture.item(
            id: "a1", backend: "codex", repoPath: "/Users/synthetic/work/Project/"
        ))
        // then
        #expect(row.meta == "Codex · Project · Waiting for resources")
    }

    @Test func givenNilMetaFieldsAndTitle_whenMapped_thenPartsAreOmittedAndTitleIsNeutral() {
        // given / when
        let bare = PendingLaunchesPresentation.row(PendingLaunchesFixture.item(id: "a1", title: nil, backend: nil, repoPath: nil))
        let blank = PendingLaunchesPresentation.row(PendingLaunchesFixture.item(id: "a2", title: " ", backend: "", repoPath: "/"))
        // then
        #expect(bare.title == "Pending launch" && bare.meta == "Waiting for resources")
        #expect(blank.title == "Pending launch" && blank.meta == "Waiting for resources")
    }

    @Test func givenUnrecognizedState_whenMapped_thenNeutralRowWithoutInferredMetadata() {
        // given / when
        let row = PendingLaunchesPresentation.row(PendingLaunchesFixture.item(id: "a1", state: "future_state"))
        // then
        #expect(row == .init(id: "a1", title: "Pending launch", meta: nil))
    }

    @Test(arguments: ["refused", "unknown", "recorded", "not_found"])
    func givenNonPendingDisposition_whenMapped_thenNeutralRowWithIDOnly(disposition: String) {
        // given / when
        let row = PendingLaunchesPresentation.row(PendingLaunchesFixture.item(id: "a1", disposition: disposition))
        // then
        #expect(row == .init(id: "a1", title: "Pending launch", meta: nil))
    }
}
