import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowBuilderPresentationTests

@Suite struct WorkflowBuilderPresentationTests {
    @Test func givenLivePlanUpdate_whenMappingEntries_thenIdentitySurvivesOrchestratorCompletion() throws {
        // given
        let pending: [String: JSONValue] = ["id": .string("task-1"), "title": .string("Review"), "status": .string("pending")]
        var completed = pending
        completed["status"] = .string("completed")
        completed["completed_by_activation_id"] = .string("orchestrator-2")
        // when / then
        #expect(try #require(WorkflowPlanEntry(pending)).id == #require(WorkflowPlanEntry(completed)).id)
        #expect(WorkflowPlanEntry(completed)?.raw["status"]?.stringValue == "completed")
    }

    @Test(arguments: [false, true])
    func givenHistoricalBuilder_whenProjectingMembers_thenOnlyInitialInjectedRequestIsHidden(_ marked: Bool) throws {
        // given
        let task = try #require(TaskInfo(.object(["task_id": .string("old"), "workflow_builder": .bool(marked)])))
        let events = try [
            #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","seq":1,"kind":"task_started","prompt":"injected scaffold"}"#,
            #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
            + #""seq":2,"kind":"user_message","text":"injected scaffold","source":"initial"}"#,
            #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
            + #""seq":3,"kind":"user_message","text":"keep feedback","source":"live"}"#,
            #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","seq":4,"kind":"assistant_text","text":"keep explanation"}"#
        ].map { try #require(TaskEvent(line: $0)) }
        let items = Timeline.items(from: events)
        // when
        let member = WorkflowBuilderPresentation.conversationMember(task: task, items: items, prompt: "injected scaffold", isBuilder: true)
        // then
        #expect(member.prompt == (marked ? "injected scaffold" : WorkflowBuilderPresentation.historicalRequest))
        #expect(member.items.suffix(2) == items.suffix(2))
        let rows = ConversationTimeline.rows(itemMembers: [member, member])
        #expect(rows.contains { row in
            if case let .separator(text) = row.kind { return text == member.prompt }
            return false
        })
        if marked {
            #expect(member.items == items)
        } else {
            guard case let .started(started) = member.items[0].body,
                  case let .message(text, _) = member.items[1].body else { Issue.record("Missing projected initial events"); return }
            #expect(started.prompt == WorkflowBuilderPresentation.historicalRequest)
            #expect(text == WorkflowBuilderPresentation.historicalRequest)
        }
        #expect(WorkflowBuilderPresentation.conversationMember(task: task, items: items, prompt: "injected scaffold", isBuilder: false).items == items)
    }

    @Test(arguments: [0, 0.5, 1, 180, 460, 500, 720, 760, 1000, 1440] as [CGFloat])
    func givenMainViewportWidth_whenBudgetingBuilderWorkspace_thenPanesAndDividerFitWithoutNegativeCanvas(_ width: CGFloat) {
        // given / when
        let layout = WorkflowBuilderLayout.widths(viewport: width)
        // then
        #expect(layout.canvas >= 0)
        #expect(layout.activity >= 0)
        #expect(layout.activity <= 460)
        #expect(layout.divider >= 0)
        #expect(layout.divider <= 1)
        #expect(abs(layout.canvas + layout.activity + layout.divider - width) < 0.001)
        if width > 0 { #expect(layout.divider == min(1, width)) }
        #expect(layout.activity == min(460, max(0, width - 1)))
        if width >= 461 {
            #expect(layout.activity == 460)
            #expect(layout.canvas == width - 461)
            #expect(layout.divider == 1)
        }
    }

    @Test(arguments: [-100, CGFloat.infinity, -CGFloat.infinity, CGFloat.nan])
    func givenInvalidViewport_whenBudgetingBuilderWorkspace_thenNoUnboundedOrNegativeFrameIsProduced(_ width: CGFloat) {
        // given / when
        let layout = WorkflowBuilderLayout.widths(viewport: width)
        // then
        #expect(layout.canvas == 0)
        #expect(layout.activity == 0)
        #expect(layout.divider == 0)
    }

    @Test func givenBuilderMount_whenChoosingChrome_thenOnlyBuilderOmitsBothLegacyAndStandalonePanes() {
        // given / when / then
        #expect(!TaskDetailChrome.builder.showsLegacyPane)
        #expect(TaskDetailChrome.embedded.showsLegacyPane)
        #expect(TaskDetailChrome.group.showsLegacyPane)
        #expect(!TaskDetailChrome.standalone.showsLegacyPane)
        #expect(TaskDetailChrome.builder != .embedded)
        #expect(TaskDetailChrome.builder != .standalone)
    }

    @Test func givenBlankRepository_whenSubmitting_thenOnlyGenerationAllowsOmission() {
        // given / when / then
        #expect(WorkflowBuilderLayout.canSubmit(isGenerating: true, isBusy: false, name: "draft", repo: "", prompt: "add review"))
        #expect(!WorkflowBuilderLayout.canSubmit(isGenerating: false, isBusy: false, name: "draft", repo: "", prompt: "run"))
        #expect(!WorkflowBuilderLayout.canSubmit(isGenerating: true, isBusy: true, name: "draft", repo: "", prompt: "add review"))
    }

    @Test func givenBuilderWorkflowJsonRow_whenProjected_thenFriendlyMessagePreservesIdentityAndOtherMessages() throws {
        // given
        let text = #"{"nodes":[{"id":"start","type":"start"}],"connections":[]}"#
        let payload: JSONValue = .object([
            "product": .string("harflow"), "format": .string("harflow.event"), "v": .number(1),
            "product_version": .string("1.0.0"), "seq": .number(2),
            "kind": .string("assistant_text"), "text": .string(text)
        ])
        let event = try #require(TaskEvent(line: payload.rendered()))
        let item = try #require(Timeline.items(from: [event]).first)
        let row = ConversationTimelineRow(id: "task:2", taskID: "task", timestamp: nil, kind: .item(item), live: false)
        // when
        let projected = try #require(WorkflowBuilderPresentation.visibleRows([row]).first)
        // then
        #expect(projected.id == row.id)
        #expect(projected.taskID == row.taskID)
        guard case let .item(mapped) = projected.kind, case let .text(message, _) = mapped.body else {
            Issue.record("Expected a readable builder response")
            return
        }
        #expect(message == WorkflowBuilderPresentation.proposalSummary)
        #expect(item.body != mapped.body)
    }

    @Test func givenUserAuthoredWorkflowJson_whenProjected_thenUserMessageIsUnchanged() throws {
        // given
        let text = #"{"nodes":[{"id":"start","type":"start"}],"connections":[]}"#
        let payload: JSONValue = .object([
            "product": .string("harflow"), "format": .string("harflow.event"), "v": .number(1),
            "product_version": .string("1.0.0"), "seq": .number(2),
            "kind": .string("user_message"), "text": .string(text)
        ])
        let event = try #require(TaskEvent(line: payload.rendered()))
        let item = try #require(Timeline.items(from: [event]).first)
        let row = ConversationTimelineRow(id: "task:2", taskID: "task", timestamp: nil, kind: .item(item), live: false)
        // when / then
        #expect(WorkflowBuilderPresentation.visibleRows([row]) == [row])
    }

    @Test func givenWorkflowDefinitionJson_whenProjectingBuilderOutput_thenDefinitionHiddenAndOtherJsonPreserved() {
        // given
        let workflow = #"{"nodes":[{"id":"start","type":"start"},{"id":"end","type":"end"}],"connections":[{"source":"start","target":"end"}]}"#
        // when / then
        #expect(WorkflowBuilderPresentation.isDefinition(workflow))
        #expect(WorkflowBuilderPresentation.isDefinition("```json\n" + workflow + "\n```"))
        #expect(WorkflowBuilderPresentation.isDefinition("```\n" + workflow + "\n```"))
        #expect(WorkflowBuilderPresentation.projectedText("Added review.\n```json\n" + workflow + "\n```") == "Added review.")
        #expect(!WorkflowBuilderPresentation.isDefinition(#"{"tests":["passed"],"result":"success"}"#))
        #expect(!WorkflowBuilderPresentation.isDefinition("Here is an explanation: " + workflow))
        #expect(WorkflowBuilderPresentation.summary(workflow) == WorkflowBuilderPresentation.proposalSummary)
        #expect(WorkflowBuilderPresentation.summary("Added review after implementation.") == "Added review after implementation.")
    }
}
