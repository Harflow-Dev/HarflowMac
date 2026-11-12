import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

extension ParallelVMTests {
    @Test func givenRecoveredToolEvidence_whenColumnBuilds_thenRowsHaveSeparateGenerationAndCapturedFactsStayQualified() throws {
        // given
        let task = task(id: "recovery", status: "completed")
        let capturedItems = [PreviewFixtures.textItem("Captured prose", seq: 7)]
        let frame = FeatureObservationFixture.frame(id: task.taskID, items: capturedItems, availability: .available)
        let eventLine = #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"0.0.8","seq":7,"#
            + #""kind":"tool_call","call_id":"recovery-call","tool":"Read","category":"read","input_preview":"Recovered only"}"#
        let event = try #require(TaskEvent(line: eventLine))
        let generation = UUID()
        var member = ParallelMemberInput(task: task, items: capturedItems, prompt: nil, availability: .available, observation: frame)
        member.recoveredTranscript = RecoveredTranscriptFrame(generation: generation, events: [event], items: Timeline.items(from: [event]))
        let base = ParallelColumnPresentation(id: task.id, task: task, title: task.id, subtitle: task.backend,
            isBusy: false, outcomeMessage: nil, showPrompt: false, start: task.startedAt, memberTaskIDs: [task.id])
        // when
        let presentation = try ParallelPresentationBuilder.build(.init(base: base, members: [member], events: frame.events, snapshot: nil))
        // then
        #expect(presentation.stepCountText == "1 activity item")
        #expect(presentation.noToolCallsText == "No tool calls observed in the available captured history")
        #expect(presentation.rows.contains { row in
            if case .separator(let text) = row.kind { return text == "Recovered transcript · display-only; excluded from captured activity facts" }
            return false
        })
        let recoveredRows = presentation.rows.filter { $0.id.contains("#recovered:") }
        #expect(recoveredRows.count == 2)
        #expect(recoveredRows.allSatisfy { $0.id.contains(generation.uuidString) && !$0.live })
        #expect(frame.summary.counts?.toolCalls == 0)
        #expect(Set(presentation.rows.map(\.id)).count == presentation.rows.count)
        // A refreshed recovery generation cannot reuse old recovered-row identity.
        member.recoveredTranscript = RecoveredTranscriptFrame(generation: UUID(), events: [event], items: Timeline.items(from: [event]))
        let refreshed = try ParallelPresentationBuilder.build(.init(base: base, members: [member], events: frame.events, snapshot: nil))
        #expect(Set(recoveredRows.map(\.id)).isDisjoint(with: refreshed.rows.map(\.id)))
    }
}
