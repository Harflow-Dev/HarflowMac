import Foundation
import HfRepository
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

// MARK: - TaskStateTreatmentTests

struct TaskStateTreatmentTests {
    private func treatment(_ status: TaskStatus, owner: String? = nil, exit: Int? = nil,
                           log: EventLogState? = nil, matching: Bool = true, taken: Bool = false) -> TaskStateTreatment? {
        .project(taskID: "task", evidence: .init(status: status, takenOver: taken,
            snapshotStatus: matching ? status : nil, exitCode: exit, logState: log, ownerState: owner),
            isBusy: false, canCancel: true, hasResumeCommand: false)
    }

    @Test func givenMatchingSnapshots_whenProjected_thenOnlySupportedTreatmentsAppear() {
        // given / when / then
        #expect(treatment(.running, owner: "dead")?.kind == .ownerLost)
        #expect(treatment(.running, owner: "undecidable")?.kind == .unverified)
        #expect(treatment(.completed)?.kind == .reconstructed)
        #expect(treatment(.failed, log: .incomplete)?.kind == .unknownFailed)
    }

    @Test func givenUnsupportedEvidence_whenProjected_thenNoTreatmentAppears() {
        // given
        let statuses: [TaskStatus] = [.running, .completed, .failed, .cancelled, .timedOut, .other("pending")]
        // when / then
        for status in statuses {
            #expect(treatment(status, owner: "dead", log: .incomplete, matching: false) == nil)
            #expect(treatment(status, owner: "dead", log: .incomplete, taken: true) == nil)
        }
        for owner in [nil, "alive", "unknown", "uncertain", ""] as [String?] {
            #expect(treatment(.running, owner: owner) == nil)
        }
        #expect(TaskStateTreatment.project(taskID: "task", evidence: nil, isBusy: false,
            canCancel: true, hasResumeCommand: false) == nil)
        let mismatched = TaskSnapshotEvidence(status: .running, takenOver: false, snapshotStatus: .completed,
            exitCode: nil, logState: .incomplete, ownerState: "dead")
        #expect(TaskStateTreatment.project(taskID: "task", evidence: mismatched, isBusy: false,
            canCancel: true, hasResumeCommand: false) == nil)
        #expect(treatment(.cancelled, log: .incomplete) == nil)
        #expect(treatment(.timedOut, log: .incomplete) == nil)
        #expect(treatment(.completed, exit: 0) == nil)
        #expect(treatment(.failed, exit: 1, log: .incomplete) == nil)
        #expect(treatment(.failed, log: .final) == nil)
        #expect(treatment(.failed) == nil)
        #expect(treatment(.other("pending"), owner: "dead") == nil)
    }

    private func model(_ count: Int, kind: TaskStateTreatment.Kind) -> ActivityFeedNativeModel {
        let rows = (1 ... count).map { ActivityRow.single(ActivityFixture.text($0), markdown: nil) }
        return .init(shownRows: rows, allRowIDs: rows.map(\.id), start: nil, emptyText: nil,
            horizontalPadding: 0, showsPromptBubble: false, expandedGroups: [], tailPresentation: .plainText("tail"),
            history: .init(), paginationRevision: 0, visible: true, loading: false,
            stateTreatment: .init(taskID: "task", kind: kind))
    }

    @Test func givenTreatments_whenBuildingEntries_thenOrderIdentityAndEqualityIncludeThem() {
        // given
        let leading = model(2, kind: .reconstructed)
        let trailing = model(2, kind: .ownerLost)
        // when
        let notice = ActivityFeedNativeEntries.build(model: leading, header: .beginning, following: false, mountedIDs: [])
        let banner = ActivityFeedNativeEntries.build(model: trailing, header: nil, following: false, mountedIDs: [])
        // then
        #expect(notice[1].id == "activity-task-state-task")
        #expect(notice[1].anchorID == notice[1].id)
        #expect(banner[banner.count - 2].id == notice[1].id)
        #expect(banner[banner.count - 3].id == "activity-feed-tail")
        #expect(leading != trailing)
        var busy = trailing
        busy.stateTreatment?.isStopDisabled = true
        #expect(busy != trailing)
        var copy = trailing
        copy.stateTreatment?.showsCopyResumeCommand = true
        #expect(copy != trailing)
    }

    @Test func givenTrailingBanner_whenAppendingRows_thenNativeTailInsertRemainsAvailable() {
        // given
        let previous = ActivityFeedNativeEntries.build(model: model(2, kind: .ownerLost), header: nil, following: false, mountedIDs: [])
        let next = ActivityFeedNativeEntries.build(model: model(3, kind: .ownerLost), header: nil, following: false, mountedIDs: [])
        // when
        let plan = ActivityFeedNativePlan.plan(previous: previous, next: next)
        // then
        #expect(plan == .tailInsert(removeLeading: 0, insertAt: 2, count: 1))
    }
}
