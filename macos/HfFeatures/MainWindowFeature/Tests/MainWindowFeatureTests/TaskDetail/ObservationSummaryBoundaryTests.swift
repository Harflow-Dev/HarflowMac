import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor
extension TaskDetailVMTests {
    @Test(arguments: [ObservedActivitySummary.State.unavailable, .limited])
    func givenUnknownMemberSummaryWhileLoading_whenBuilt_thenAggregateFilesAreWithheld(state: ObservedActivitySummary.State) {
        // given
        let harness = makeSUT(taskID: "current")
        let first = task(id: "first", status: "completed")
        let current = task(id: "current", status: "completed")
        harness.sut.conversationMembers = [first, current]
        harness.sut.conversationLoading = true
        harness.sut.observationFrames = [
            first.taskID: EventObservationFrame(taskID: first.taskID, scope: FeatureObservationFixture.scope,
                summary: .init(state: .observed, counts: ActivityCounts(), files: [EditedFile(path: "known.swift", status: .edited)], totalFiles: 1)),
            current.taskID: EventObservationFrame(taskID: current.taskID, scope: FeatureObservationFixture.scope,
                summary: .init(state: state, reasons: [.capacity]))
        ]
        // when
        harness.sut.recomputeSummary(task: current)
        // then
        #expect(harness.sut.summaryModel.editedFilesAvailability == .unavailable)
        #expect(harness.sut.summaryModel.editedFiles.isEmpty)
        #expect(harness.sut.summaryModel.additionalFileCount == 0)
        #expect(harness.sut.summaryModel.onLoadMoreFiles == nil)
    }

    @Test func givenQualifiedBoundedFileSummary_whenMoreFilesExistThanVisible_thenNoUnsupportedPagingActionIsOffered() {
        // given
        let harness = makeSUT()
        let member = task(status: "completed")
        harness.sut.conversationMembers = [member]
        harness.sut.conversationLoading = false
        harness.sut.observationFrames[member.taskID] = EventObservationFrame(taskID: member.taskID, scope: FeatureObservationFixture.scope,
            summary: .init(state: .observed, counts: ActivityCounts(), files: [EditedFile(path: "visible.swift", status: .edited)], totalFiles: 5))
        // when
        harness.sut.recomputeSummary(task: member)
        // then
        #expect(harness.sut.summaryModel.editedFilesAvailability == .available)
        #expect(harness.sut.summaryModel.editedFiles.map(\.path) == ["visible.swift"])
        #expect(harness.sut.summaryModel.additionalFileCount == 4)
        #expect(harness.sut.summaryModel.onLoadMoreFiles == nil)
    }
}
