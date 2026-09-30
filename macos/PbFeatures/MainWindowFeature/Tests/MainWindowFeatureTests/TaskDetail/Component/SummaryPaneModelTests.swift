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

    // MARK: - Hero (D9)

    private func build(_ fields: [String: JSONValue]) -> SummaryPaneModel {
        SummaryPaneModel.build(task: task(fields), summary: nil, events: [], eventsAvailability: .available)
    }

    @Test(arguments: [
        ("completed", "Done in 21 min"), ("failed", "Failed after 21 min"),
        ("cancelled", "Cancelled after 21 min"), ("timed_out", "Timed out after 21 min")
    ])
    func givenASettledTaskWithAnExitCode_whenBuilt_thenTheHeadlineCarriesTheDuration(status: String, headline: String) {
        // given
        let fields: [String: JSONValue] = ["status": .string(status), "exit_code": .number(0), "duration_seconds": .number(1260)]
        // when
        let model = build(fields)
        // then
        #expect(model.hero?.headline == headline)
        #expect(model.hero?.isRunning == false)
        #expect(model.statTiles.first == SummaryStatTile(title: "Duration", value: "21 min"))
    }

    @Test(arguments: [("completed", "Done"), ("failed", "Failed"), ("cancelled", "Cancelled"), ("timed_out", "Timed out")])
    func givenASettledTaskWithoutAnExitCode_whenBuilt_thenTheHeadlineIsStatusOnlyAndThereIsNoDurationTile(
        status: String, headline: String
    ) {
        // given
        let fields: [String: JSONValue] = ["status": .string(status), "duration_seconds": .number(1260)]
        // when
        let model = build(fields)
        // then
        #expect(model.hero?.headline == headline)
        #expect(model.durationSeconds == nil)
        #expect(!model.statTiles.contains { $0.title == "Duration" })
    }

    @Test func givenARunningTask_whenBuilt_thenTheHeroIsRunningWithItsStartAndNoDurationTile() {
        // given
        let started = "2026-01-01T00:00:00Z"
        let fields: [String: JSONValue] = ["status": .string("running"), "started_at": .string(started), "exit_code": .number(0)]
        // when
        let model = build(fields)
        // then
        #expect(model.hero?.isRunning == true)
        #expect(model.hero?.startedAt != nil)
        #expect(model.durationSeconds == nil)
        #expect(model.statTiles.isEmpty)
    }

    @Test func givenTurnsReported_whenBuilt_thenTheSublineCarriesThem() {
        // given / when
        let many = build(["num_turns": .number(3)])
        let one = build(["num_turns": .number(1)])
        // then
        #expect(many.hero?.turnsText == "3 turns")
        #expect(one.hero?.turnsText == "1 turn")
        #expect(many.hero?.backend == "claude")
    }

    @Test func givenNoTurnsReported_whenBuilt_thenTheSublineOmitsThem() {
        // given / when
        let model = build([:])
        // then
        #expect(model.hero?.turnsText == nil)
    }

    @Test func givenSecondsAndHours_whenFormatted_thenTheDurationIsHumanReadable() {
        // given / when / then
        #expect(SummaryPaneModel.durationText(45) == "45 sec")
        #expect(SummaryPaneModel.durationText(1260) == "21 min")
        #expect(SummaryPaneModel.durationText(3600) == "1 h")
        #expect(SummaryPaneModel.durationText(3900) == "1 h 5 min")
    }

    // MARK: - Stat tiles: each only when reported

    @Test func givenNoMetricsAtAll_whenBuilt_thenThereAreNoTilesAndNoTurns() {
        // given / when
        let model = build([:])
        // then
        #expect(model.statTiles.isEmpty)
        #expect(model.numTurns == nil)
        #expect(model.inputTokens == nil)
        #expect(model.outputTokens == nil)
        #expect(model.costUSD == nil)
    }

    @Test func givenTokensAndCostReported_whenBuilt_thenBothTilesAppear() {
        // given
        let fields: [String: JSONValue] = [
            "usage": .object(["input_tokens": .number(48210), "output_tokens": .number(3150)]), "total_cost_usd": .number(0.0123)
        ]
        // when
        let tiles = build(fields).statTiles
        // then
        #expect(tiles.map(\.title) == ["Tokens (in / out)", "Cost"])
        #expect(tiles.last?.value == "$0.0123")
        #expect(tiles.first?.value == "48210 / 3150")
    }

    @Test func givenOnlyOneTokenCountReported_whenBuilt_thenTheMissingSideIsADash() {
        // given / when
        let tiles = build(["usage": .object(["input_tokens": .number(7)])]).statTiles
        // then
        #expect(tiles == [SummaryStatTile(title: "Tokens (in / out)", value: "7 / –")])
    }

    @Test func givenOnlyTurnsReported_whenBuilt_thenNoTokenOrCostTileAppears() {
        // given / when
        let model = build(["num_turns": .number(3)])
        // then
        #expect(model.statTiles.isEmpty)
        #expect(model.numTurns == 3)
    }

    // MARK: - Edited file rows (D8)

    @Test func givenANestedPath_whenMappedToARow_thenItHasNameFolderAndFullPathLabel() {
        // given
        let file = EditedFile(path: "src/app/View.swift", status: .edited)
        // when
        let row = SummaryFileRow(file)
        // then
        #expect(row.name == "View.swift")
        #expect(row.parentFolder == "src/app")
        #expect(row.fullPath == "src/app/View.swift")
        #expect(row.accessibilityLabel == "Edited src/app/View.swift")
    }

    @Test func givenABarePath_whenMappedToARow_thenThereIsNoParentFolder() {
        // given / when
        let row = SummaryFileRow(EditedFile(path: "README.md", status: .edited))
        // then
        #expect(row.name == "README.md")
        #expect(row.parentFolder == nil)
    }

    @Test func givenEachEditedFileState_whenMappedToRows_thenTheStatesAndLabelsDiffer() {
        // given
        let files = [
            EditedFile(path: "a/x.swift", status: .edited), EditedFile(path: "a/y.swift", status: .failed),
            EditedFile(path: "a/z.swift", status: .unconfirmed)
        ]
        // when
        let rows = files.map(SummaryFileRow.init)
        // then
        #expect(rows.map(\.status) == [.edited, .failed, .unconfirmed])
        #expect(rows.map(\.accessibilityLabel) == [
            "Edited a/x.swift", "Edit failed a/y.swift", "Edit unconfirmed, no result recorded a/z.swift"
        ])
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
