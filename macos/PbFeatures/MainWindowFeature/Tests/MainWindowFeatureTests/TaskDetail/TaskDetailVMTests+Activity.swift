import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

/// Redesign phase 6: `recomputeTimeline` folds the raw rows into Activity feed rows, keeps the raw
/// rows for the inspector's step count, and hands the feed a live step and an update token.
@MainActor
extension TaskDetailVMTests {

    private func events(_ lines: [String]) -> [TimelineItem] {
        Timeline.items(from: lines.compactMap { TaskEvent(line: $0) })
    }

    @Test
    func givenAdjacentReadsAndAPendingCommand_whenBuildingTheTimeline_thenTheFeedFoldsThemAndKeepsRawRows() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.itemsOverride.value = events([
            #"{"v":1,"seq":0,"kind":"task_started","prompt":"Fix it","backend":"claude","freedom":"read_only"}"#,
            #"{"v":1,"seq":1,"kind":"user_message","text":"Fix it","source":"initial"}"#,
            #"{"v":1,"seq":2,"kind":"tool_call","call_id":"a","tool":"Read","category":"read","path":"/x/A.swift","input_preview":"A"}"#,
            #"{"v":1,"seq":3,"kind":"tool_result","call_id":"a","ok":true}"#,
            #"{"v":1,"seq":4,"kind":"tool_call","call_id":"b","tool":"Read","category":"read","path":"/x/B.swift","input_preview":"B"}"#,
            #"{"v":1,"seq":5,"kind":"tool_result","call_id":"b","ok":true}"#,
            #"{"v":1,"seq":6,"kind":"tool_call","call_id":"c","tool":"Bash","category":"shell","command":"swift test","input_preview":"swift test"}"#
        ])

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([running])

        // then
        await waitUntil { !harness.sut.timelineModel.rows.isEmpty }
        let model = harness.sut.timelineModel
        #expect(model.rows.count == 5, "raw rows are kept for the inspector's step count")
        #expect(model.activityRows.map { $0.group?.summary ?? "row" } == ["row", "Read 2 files", "Ran 1 command"])
        #expect(model.activityRows.first?.group == nil)
        #expect(model.liveStep?.text == "Running swift test…")
        #expect(model.stepCountText == "5 steps")
    }

    @Test
    func givenAFinishedTaskWithAnUnresolvedCall_whenBuildingTheTimeline_thenThereIsNoLiveStep() async {
        // given
        let harness = makeSUT()
        let finished = task(status: "completed")
        harness.detailBox.value = finished
        harness.itemsOverride.value = events([
            #"{"v":1,"seq":0,"kind":"tool_call","call_id":"a","tool":"Read","category":"read","path":"/x/A.swift","input_preview":"A"}"#
        ])

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([finished])

        // then
        await waitUntil { !harness.sut.timelineModel.rows.isEmpty }
        #expect(harness.sut.timelineModel.liveStep == nil)
        #expect(harness.sut.timelineModel.activityRows.first?.group?.isRunning == false)
    }

    @Test
    func givenAResultArrivesForAPendingCall_whenTheItemsRepublish_thenTheUpdateTokenChanges() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        let call = #"{"v":1,"seq":0,"kind":"tool_call","call_id":"a","tool":"Read","category":"read","path":"/x/A.swift","input_preview":"A"}"#
        harness.itemsOverride.value = events([call])
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { !harness.sut.timelineModel.rows.isEmpty }
        let before = harness.sut.timelineModel.updateToken

        // when
        harness.itemsSubject.send(events([call, #"{"v":1,"seq":1,"kind":"tool_result","call_id":"a","ok":true}"#]))

        // then
        await waitUntil { harness.sut.timelineModel.updateToken != before }
        #expect(harness.sut.timelineModel.rows.count == 1)
        #expect(harness.sut.timelineModel.liveStep?.text == "Thinking…")
    }
}
