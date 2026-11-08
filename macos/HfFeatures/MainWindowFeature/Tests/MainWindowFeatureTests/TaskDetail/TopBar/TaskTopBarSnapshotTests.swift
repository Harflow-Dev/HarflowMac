//
//  TaskTopBarSnapshotTests.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskTopBarSnapshotTests

/// The toolbar snapshot's equality with chips: drawn chip inputs and the narrow flag re-evaluate the presenter,
/// non-drawn metadata does not.
@MainActor
@Suite struct TaskTopBarSnapshotTests {

    private func snapshot(_ vm: TaskDetailViewModelMock, task: TaskInfo, chips: TaskTopBarChips?) -> TaskDetailToolbarSnapshot {
        TaskDetailToolbarSnapshot(vm, task: task, showsInspector: false, isRightPane: true, chips: chips)
    }

    private func chips(continuity: Bool = false, notices: Int = 0, access: String? = "Read-only", narrow: Bool = false) -> TaskTopBarChips {
        TaskTopBarChips(showsContinuity: continuity, noticeCount: notices, accessText: access, isNarrow: narrow)
    }

    @Test func givenEqualChips_whenSnapshotsAreCompared_thenTheyAreEqual() throws {
        // given
        let vm = TaskDetailViewModelMock()
        let task = try #require(vm.task)

        // when / then
        #expect(snapshot(vm, task: task, chips: chips()) == snapshot(vm, task: task, chips: chips()))
    }

    @Test func givenAChipChange_whenSnapshotsAreCompared_thenEachDrawnInputRefreshesThem() throws {
        // given
        let vm = TaskDetailViewModelMock()
        let task = try #require(vm.task)
        let baseline = snapshot(vm, task: task, chips: chips())

        // when / then
        #expect(baseline != snapshot(vm, task: task, chips: chips(narrow: true)))
        #expect(baseline != snapshot(vm, task: task, chips: chips(continuity: true)))
        #expect(baseline != snapshot(vm, task: task, chips: chips(notices: 1)))
        #expect(snapshot(vm, task: task, chips: chips(notices: 1)) != snapshot(vm, task: task, chips: chips(notices: 2)))
        #expect(baseline != snapshot(vm, task: task, chips: chips(access: "Full access")))
        #expect(baseline != snapshot(vm, task: task, chips: chips(access: nil)))
        #expect(baseline != snapshot(vm, task: task, chips: nil))
    }

    @Test func givenNonDrawnMetadata_whenSnapshotsAreCompared_thenTheyStayEqualWithChips() throws {
        // given
        let vm = TaskDetailViewModelMock()
        let task = try #require(vm.task)
        var raw = task.raw
        raw["summary"] = .string("New activity")
        raw["usage"] = .object(["output_tokens": .number(900)])
        raw["num_turns"] = .number(7)
        let changed = try #require(TaskInfo(.object(raw)))

        // when / then
        #expect(snapshot(vm, task: task, chips: chips(notices: 2)) == snapshot(vm, task: changed, chips: chips(notices: 2)))
    }

    @Test func givenNoChips_whenBuilt_thenTheNonStandaloneMountsKeepTheirSnapshotShape() throws {
        // given
        let vm = TaskDetailViewModelMock()
        let task = try #require(vm.task)

        // when
        let legacy = TaskDetailToolbarSnapshot(vm, task: task, showsInspector: false)

        // then
        #expect(legacy.chips == nil)
    }
}
