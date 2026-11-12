import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

extension ParallelVMTests {
    @Test func givenAGroupLane_whenPublished_thenItHasNoTakeoverAndItsLaneFieldsAreSet() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(id: "t1", status: "running")
        harness.tasksBox.value["t1"] = running
        sut.didAppear()
        defer { sut.didDisappear() }

        // when
        harness.tasksSubject.send([running])
        await waitUntil { sut.columns.count == 1 && sut.isPresentationSettled }

        // then
        let column = sut.columns.first
        #expect(column?.onTapTakeover == nil)
        #expect(column?.caption == "Claude")
        #expect(column?.harnessName == "Claude")
        #expect(column?.status?.label == "Running")
        #expect(column?.subtitle == "", "lanes use the caption; only the inspector keeps the subtitle")
    }

    @Test func givenTheGraphInspector_whenPublished_thenItKeepsTakeoverAndTheSubtitle() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut.makeWorkflowActivity()
        let running = task(id: "t1", status: "running")
        harness.tasksBox.value["t1"] = running
        sut.didAppear()
        defer { sut.didDisappear() }

        // when
        harness.tasksSubject.send([running])
        await waitUntil { sut.columns.count == 1 && sut.isPresentationSettled }

        // then
        #expect(sut.columns.first?.onTapTakeover != nil)
        #expect(sut.columns.first?.chrome == .inspector)
        #expect(sut.columns.first?.subtitle.hasPrefix("Claude") == true)
    }

    @Test func givenALane_whenOpenTaskIsChosen_thenTheCurrentMemberIsRouted() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let running = task(id: "t1", status: "running")
        harness.tasksBox.value["t1"] = running
        sut.didAppear()
        defer { sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { sut.columns.count == 1 && sut.isPresentationSettled }

        // when
        sut.columns.first?.onTapOpenTask()

        // then
        verify(harness.routing).selectTask(.value("t1")).called(1)
    }
}
