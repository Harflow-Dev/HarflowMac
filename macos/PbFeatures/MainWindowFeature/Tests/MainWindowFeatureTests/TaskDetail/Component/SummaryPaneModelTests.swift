@testable import MainWindowFeature
@testable import MonitorCore
import Testing

@Suite struct SummaryPaneModelTests {

    private func task(_ fields: [String: JSONValue] = [:]) -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string("t1"), "backend": .string("claude"), "status": .string("running")]
        for (key, value) in fields { object[key] = value }
        return TaskInfo(.object(object))!
    }

    // MARK: - Running vs. finished answer text

    @Test func givenARunningTaskWithNoSummary_whenBuilt_thenThePlaceholderIsNoAnswerYet() {
        // given
        let running = task(["status": .string("running")])
        // when
        let model = SummaryPaneModel.build(task: running, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.finalAnswer == nil)
        #expect(model.finalAnswerPlaceholder == "No answer yet.")
    }

    @Test func givenAFinishedTaskWithNoSummary_whenBuilt_thenThePlaceholderIsNoFinalAnswer() {
        // given
        let done = task(["status": .string("completed")])
        // when
        let model = SummaryPaneModel.build(task: done, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.finalAnswer == nil)
        #expect(model.finalAnswerPlaceholder == "No final answer.")
    }

    @Test func givenASummary_whenBuilt_thenItIsShownRegardlessOfRunState() {
        // given
        let running = task(["status": .string("running")])
        // when
        let model = SummaryPaneModel.build(task: running, summary: "**done**", events: [], eventsAvailability: .available)
        // then
        #expect(model.finalAnswer == "**done**")
    }

    @Test func givenAnEmptySummaryString_whenBuilt_thenItIsTreatedAsNoSummary() {
        // given
        let done = task(["status": .string("completed")])
        // when
        let model = SummaryPaneModel.build(task: done, summary: "", events: [], eventsAvailability: .available)
        // then
        #expect(model.finalAnswer == nil)
        #expect(model.finalAnswerPlaceholder == "No final answer.")
    }

    // MARK: - Refusals & warnings: presence/absence, denial description fallback

    @Test func givenNoDenialsAndNoNotices_whenBuilt_thenRefusalLinesIsEmpty() {
        // given / when
        let model = SummaryPaneModel.build(task: task(), summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.refusalLines.isEmpty)
    }

    @Test func givenADenialWithACommand_whenBuilt_thenTheLineIsTheCommand() {
        // given
        let denial: JSONValue = .object(["command": .string("git commit -am wip"), "title": .string("Allow bash?")])
        let withDenial = task(["permission_denials": .array([denial])])
        // when
        let model = SummaryPaneModel.build(task: withDenial, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.refusalLines == ["git commit -am wip"])
    }

    @Test func givenADenialWithNoCommand_whenBuilt_thenTheLineFallsBackToTitle() {
        // given
        let denial: JSONValue = .object(["title": .string("Allow bash?")])
        let withDenial = task(["permission_denials": .array([denial])])
        // when
        let model = SummaryPaneModel.build(task: withDenial, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.refusalLines == ["Allow bash?"])
    }

    @Test func givenADenialWithNeitherCommandNorTitle_whenBuilt_thenTheLineFallsBackToAnAction() {
        // given
        let denial: JSONValue = .object(["kind": .string("approval")])
        let withDenial = task(["permission_denials": .array([denial])])
        // when
        let model = SummaryPaneModel.build(task: withDenial, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.refusalLines == ["an action"])
    }

    @Test func givenNoticesWithNoDenials_whenBuilt_thenTheyAppearAsRefusalLines() {
        // given
        let withNotices = task(["notices": .array([.string("auto-denied: git push")])])
        // when
        let model = SummaryPaneModel.build(task: withNotices, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.refusalLines == ["auto-denied: git push"])
    }

    @Test func givenBothDenialsAndNotices_whenBuilt_thenDenialsComeFirst() {
        // given
        let denial: JSONValue = .object(["command": .string("git commit")])
        let both = task(["permission_denials": .array([denial]), "notices": .array([.string("a notice")])])
        // when
        let model = SummaryPaneModel.build(task: both, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.refusalLines == ["git commit", "a notice"])
    }

    // MARK: - Files the agent edited: availability drives presence

    @Test func givenEventsLoading_whenBuilt_thenAvailabilityIsLoading() {
        // given / when
        let model = SummaryPaneModel.build(task: task(), summary: nil, events: [], eventsAvailability: .loading)
        // then
        #expect(model.editedFilesAvailability == .loading)
        #expect(model.editedFiles.isEmpty)
    }

    @Test func givenEventsUnavailable_whenBuilt_thenAvailabilityIsUnavailable() {
        // given / when
        let model = SummaryPaneModel.build(task: task(), summary: nil, events: [], eventsAvailability: .unavailable)
        // then
        #expect(model.editedFilesAvailability == .unavailable)
    }

    @Test func givenEventsAvailableWithNoEditCalls_whenBuilt_thenEditedFilesIsEmpty() {
        // given / when — the view hides the section in this case; the model just reports empty.
        let model = SummaryPaneModel.build(task: task(), summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.editedFilesAvailability == .available)
        #expect(model.editedFiles.isEmpty)
    }

    // MARK: - Usage & cost: each row omitted when unreported, section hidden when nothing reported

    @Test func givenNoUsageFieldsAtAll_whenBuilt_thenHasUsageIsFalse() {
        // given / when
        let model = SummaryPaneModel.build(task: task(), summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(!model.hasUsage)
        #expect(model.numTurns == nil)
        #expect(model.inputTokens == nil)
        #expect(model.outputTokens == nil)
        #expect(model.costUSD == nil)
    }

    @Test func givenOnlyNumTurnsReported_whenBuilt_thenOnlyThatFieldIsSetAndHasUsageIsTrue() {
        // given
        let withTurns = task(["num_turns": .number(3)])
        // when
        let model = SummaryPaneModel.build(task: withTurns, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.hasUsage)
        #expect(model.numTurns == 3)
        #expect(model.inputTokens == nil)
        #expect(model.outputTokens == nil)
        #expect(model.costUSD == nil)
    }

    @Test func givenCostReportedWithNoOtherUsage_whenBuilt_thenCostIsSetAndOthersAreNil() {
        // given
        let withCost = task(["total_cost_usd": .number(0.0123)])
        // when
        let model = SummaryPaneModel.build(task: withCost, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.hasUsage)
        #expect(model.costUSD == 0.0123)
        #expect(model.numTurns == nil)
    }

    @Test func givenNoCostReported_whenBuilt_thenCostIsOmitted() {
        // given
        let withTurnsOnly = task(["num_turns": .number(1)])
        // when
        let model = SummaryPaneModel.build(task: withTurnsOnly, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.costUSD == nil)
    }

    // MARK: - Token key fallback (by key, never by backend name)

    @Test func givenClaudeStyleTokenKeys_whenExtracted_thenTheyAreRead() {
        // given
        let usage: [String: JSONValue] = ["input_tokens": .number(100), "output_tokens": .number(20)]
        // when
        let (input, output) = SummaryPaneModel.tokens(from: usage)
        // then
        #expect(input == 100)
        #expect(output == 20)
    }

    @Test func givenOpencodeStyleTokenKeys_whenExtracted_thenTheyAreRead() {
        // given
        let usage: [String: JSONValue] = ["input": .number(55), "output": .number(9)]
        // when
        let (input, output) = SummaryPaneModel.tokens(from: usage)
        // then
        #expect(input == 55)
        #expect(output == 9)
    }

    @Test func givenBothKeyShapesPresent_whenExtracted_thenTheLongFormWins() {
        // given — never chosen by backend name, only by which key is present; the long form is
        // checked first.
        let usage: [String: JSONValue] = ["input_tokens": .number(1), "input": .number(2), "output_tokens": .number(3), "output": .number(4)]
        // when
        let (input, output) = SummaryPaneModel.tokens(from: usage)
        // then
        #expect(input == 1)
        #expect(output == 3)
    }

    @Test func givenNoUsageObjectAtAll_whenExtracted_thenBothAreNil() {
        // given / when
        let (input, output) = SummaryPaneModel.tokens(from: nil)
        // then
        #expect(input == nil)
        #expect(output == nil)
    }

    @Test func givenATaskWithOpencodeStyleUsage_whenBuilt_thenTheModelReadsItByKey() {
        // given
        let withUsage = task(["usage": .object(["input": .number(10), "output": .number(2)])])
        // when
        let model = SummaryPaneModel.build(task: withUsage, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.inputTokens == 10)
        #expect(model.outputTokens == 2)
    }

    // MARK: - What was enforced: presence/absence

    @Test func givenNoEnforcement_whenBuilt_thenEnforcementLinesIsEmpty() {
        // given / when
        let model = SummaryPaneModel.build(task: task(), summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(model.enforcementLines.isEmpty)
    }

    @Test func givenEnforcementData_whenBuilt_thenEnforcementLinesIsPopulated() {
        // given
        let withEnforcement = task(["enforcement": .object(["os_enforced": .bool(true)])])
        // when
        let model = SummaryPaneModel.build(task: withEnforcement, summary: nil, events: [], eventsAvailability: .available)
        // then
        #expect(!model.enforcementLines.isEmpty)
    }
}
