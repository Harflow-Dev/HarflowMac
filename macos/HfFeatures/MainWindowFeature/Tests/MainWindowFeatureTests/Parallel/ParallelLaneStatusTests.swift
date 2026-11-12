import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - ParallelLaneStatusTests

/// The lane head's caption and status as pure functions of the current member, its snapshot and observation frame.
@Suite struct ParallelLaneStatusTests {
    private nonisolated static let started = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ status: String, backend: String = "claude", model: String? = nil, takenOver: Bool = false,
                      exit: Int? = nil, duration: Double? = nil, owner: String? = nil) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string("t"), "backend": .string(backend), "status": .string(status),
            "started_at": .string(ISO8601DateFormatter().string(from: Self.started))
        ]
        if let model { object["model"] = .string(model) }
        if takenOver { object["taken_over"] = .bool(true) }
        if let exit { object["exit_code"] = .number(Double(exit)) }
        if let duration { object["duration_seconds"] = .number(duration) }
        if let owner { object["supervision"] = .object(["owner_state": .string(owner)]) }
        return TaskInfo(.object(object))!
    }

    // MARK: - Caption

    @Test func givenAKnownModel_whenBuildingTheCaption_thenItIsTheHarnessAndTheModel() {
        #expect(ParallelLaneStatus.caption(current: task("running", model: "Opus 5.5")) == "Claude · Opus 5.5")
    }

    @Test(arguments: [nil, "", "  "] as [String?])
    func givenAMissingOrBlankModel_whenBuildingTheCaption_thenItIsTheHarnessOnly(_ model: String?) {
        #expect(ParallelLaneStatus.caption(current: task("running", backend: "codex", model: model)) == "Codex")
    }

    @Test func givenATakenOverMember_whenBuildingTheCaption_thenTakenOverFollowsTheModel() {
        #expect(ParallelLaneStatus.caption(current: task("cancelled", model: "Opus 5.5", takenOver: true)) == "Claude · Opus 5.5 · taken over")
    }

    // MARK: - Status

    @Test func givenARunningMember_whenBuildingTheStatus_thenItIsRunningWithALiveClock() {
        // when
        let status = ParallelLaneStatus.make(current: task("running"), snapshot: nil, frame: nil)

        // then
        #expect(status.label == "Running")
        #expect(status.clock == .live(Self.started))
        #expect(status.suffix == nil)
    }

    @Test func givenADoneMemberWithExitAndDuration_whenBuildingTheStatus_thenItIsDoneWithAFixedClock() {
        // given
        let current = task("completed", exit: 0, duration: 291)

        // when
        let status = ParallelLaneStatus.make(current: current, snapshot: current, frame: nil)

        // then
        #expect(status.label == "Done")
        #expect(status.clock == .fixed(291))
    }

    @Test func givenADoneMatchingSnapshotWithoutAnExit_whenBuildingTheStatus_thenTheQualifierIsClaimed() {
        // given
        let current = task("completed")

        // when
        let status = ParallelLaneStatus.make(current: current, snapshot: current, frame: nil)

        // then
        #expect(status.label == "Done · exit not observed")
        #expect(status.clock == .none)
    }

    @Test func givenADoneListingRowAndNoSnapshot_whenBuildingTheStatus_thenNoQualifierIsClaimed() {
        // when
        let status = ParallelLaneStatus.make(current: task("completed"), snapshot: nil, frame: nil)

        // then
        #expect(status.label == "Done")
    }

    @Test func givenARunningMemberWhoseOwnerIsLost_whenBuildingTheStatus_thenTheOwnerWarningIsClaimed() {
        // given
        let current = task("running", owner: "dead")

        // when
        let status = ParallelLaneStatus.make(current: current, snapshot: current, frame: nil)

        // then
        #expect(status.label == "Running · owner lost")
    }

    @Test func givenATakenOverCancelledMember_whenBuildingTheStatus_thenTheLabelCarriesNoTakenOverText() {
        // given
        let current = task("cancelled", takenOver: true, exit: 143, duration: 271)

        // when
        let status = ParallelLaneStatus.make(current: current, snapshot: current, frame: nil)

        // then — the label is plain and the clock stays; "taken over" lives in the caption
        #expect(status.label == "Cancelled")
        #expect(status.clock == .fixed(271))
    }

    // MARK: - End row

    private func endRow(_ current: TaskInfo, snapshot: TaskInfo? = nil) -> ActivityFeedTailPresentation.SettledLine? {
        ParallelLaneStatus.settledLine(current: current, status: ParallelLaneStatus.make(current: current, snapshot: snapshot, frame: nil))
    }

    @Test func givenADoneMemberWithADuration_whenBuildingTheEndRow_thenItIsSuccessWithTheClock() {
        // when
        let line = endRow(task("completed", exit: 0, duration: 291))

        // then
        #expect(line == .init(text: "Done · 04:51", tone: .success, symbol: "checkmark"))
    }

    @Test func givenAFailedMember_whenBuildingTheEndRow_thenItIsDangerWithTheClock() {
        #expect(endRow(task("failed", exit: 1, duration: 468))?.text == "Failed · 07:48")
        #expect(endRow(task("failed", exit: 1, duration: 468))?.tone == .danger)
    }

    @Test func givenATimedOutMember_whenBuildingTheEndRow_thenItIsDanger() {
        #expect(endRow(task("timed_out", exit: 124, duration: 60))?.text == "Timed out · 01:00")
        #expect(endRow(task("timed_out", exit: 124, duration: 60))?.tone == .danger)
    }

    @Test func givenACancelledMember_whenBuildingTheEndRow_thenItIsSecondaryWithAStopGlyph() {
        #expect(endRow(task("cancelled", exit: 130, duration: 271)) == .init(text: "Cancelled · 04:31", tone: .secondary, symbol: "stop.fill"))
    }

    @Test func givenATakenOverCancelledMember_whenBuildingTheEndRow_thenTakenOverPrecedesTheClock() {
        #expect(endRow(task("cancelled", takenOver: true, exit: 130, duration: 271))?.text == "Cancelled · taken over · 04:31")
    }

    @Test func givenNoRecordedDuration_whenBuildingTheEndRow_thenThereIsNoClock() {
        #expect(endRow(task("completed"))?.text == "Done")
    }

    @Test func givenASnapshotWithoutAnExit_whenBuildingTheEndRow_thenTheQualifierIsKept() {
        // given
        let current = task("completed")
        let snapshot = task("completed")

        // when / then
        #expect(endRow(current, snapshot: snapshot)?.text == "Done · exit not observed")
    }

    @Test(arguments: ["running"])
    func givenARunningMember_whenBuildingTheEndRow_thenThereIsNone(_ status: String) {
        #expect(endRow(task(status)) == nil)
        #expect(endRow(task(status, takenOver: true)) == nil)
    }
}
