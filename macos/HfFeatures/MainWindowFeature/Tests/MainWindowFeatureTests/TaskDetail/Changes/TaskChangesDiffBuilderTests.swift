import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskChangesDiffBuilderTests

/// What is drawn for a selected row: a diff from a patch, or a note from a failed read, including the three text fixtures.
struct TaskChangesDiffBuilderTests {
    private let header = TaskChangesDiffHeader(path: "src/app.py", scope: "Committed")
    private let plainFacts = TaskChangesRowFacts(
        path: "src/app.py", scopeTitle: "Committed", hasText: true, label: nil, stateHelp: nil, countsAndPatchSeparate: false)

    private func model(_ presentation: TaskChangesDiffPresentation) throws -> TaskChangesDiffModel {
        guard case .diff(let model) = presentation else { throw TestFailure("expected a diff, got \(presentation)") }
        return model
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Fixtures

    @Test func givenTheTextCompleteFixture_whenBuilt_thenItIsTheClassifiedDiffWithoutNoticeTailOrCaption() throws {
        // given: ctl-task-changes-text-complete.json, one chunk of src/app.py (committed_range) with has_more false
        let address = ChangesJSON.selector("src/app.py")
        let patch = try ChangesJSON.patch(address, bytes: Data(ChangesJSON.textCompleteText.utf8), task: "task-changes-available")

        // when
        let result = try model(TaskChangesDiffBuilder.build(patch: patch, header: header, facts: plainFacts))

        // then
        #expect(result.header == header)
        #expect(result.notice == nil && result.tail == nil && result.caption == nil)
        #expect(result.text.lineCount == 7)
        #expect(result.drawnKinds == [0, 0, 0, 0, 1, 4, 2])
        #expect(result.drawnLines.last == "+print('b')", "an added line keeps its + prefix")
        #expect(result.drawnLines[5] == " print('a')", "a context line keeps its space prefix")
        #expect(result.lineEndingNotice == nil)
    }

    @Test func givenTheTextChunkFixtures_whenAssembledInOrder_thenTheSecondContinuesTheFirstAndTheReadIsUnfinished() throws {
        // given: ctl-task-changes-text-chunk.json (offset 0) and ctl-task-changes-text-chunk-next.json (offset = bytes so far)
        let chunks = try ChangesJSON.guideChunks()
        var assembler = TaskChangesTextAssembler(selector: chunks.selector)

        // when
        try assembler.append(chunks.first)
        try assembler.append(chunks.next)

        // then
        #expect(chunks.first.offset == 0 && chunks.next.offset == chunks.first.bytes.count)
        #expect(chunks.first.hasMore && chunks.next.hasMore)
        #expect(assembler.nextCursor == "cursor-text-3")
        #expect(throws: TaskChangesAssemblyError.unfinished) { try assembler.finish() }
    }

    @Test func givenTheSecondTextChunkFirst_whenAppended_thenTheOffsetMismatchIsRefused() throws {
        // given
        let chunks = try ChangesJSON.guideChunks()
        var assembler = TaskChangesTextAssembler(selector: chunks.selector)

        // when / then
        #expect(throws: TaskChangesAssemblyError.offsetMismatch) { try assembler.append(chunks.next) }
    }

    @Test func givenTheChunkDescriptions_whenPrinted_thenNoPatchTextAppears() throws {
        // given
        let chunks = try ChangesJSON.guideChunks()
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: Data(ChangesJSON.textCompleteText.utf8))

        // when
        let printed = [String(describing: chunks.first), String(reflecting: chunks.next), String(describing: patch), String(reflecting: patch)]

        // then
        for text in printed {
            #expect(!text.contains("documentation") && !text.contains("print("), "\(text)")
        }
    }

    // MARK: Building

    @Test func givenNonUTF8Bytes_whenBuilt_thenTheTextIsByteDecodedWithTheNoticeNotAnError() throws {
        // given
        let bytes = Data("@@ -1 +1 @@\n+caf".utf8) + Data([0xE9, 0xFF]) + Data("\n".utf8)
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: bytes)

        // when
        let result = try model(TaskChangesDiffBuilder.build(patch: patch, header: header, facts: plainFacts))

        // then
        #expect(result.notice == "Bytes, not UTF-8")
        #expect(result.drawnKinds == [UnifiedDiffLines.Kind.hunk.code, UnifiedDiffLines.Kind.added.code])
        #expect(result.drawnLines.last?.hasPrefix("+caf") == true)
    }

    @Test(arguments: [
        ("file_limit", "Stored text ends here \u{B7} 64 KiB of a larger patch"),
        ("task_limit", "Stored text ends here \u{B7} task limit"),
        ("capture_timeout", "Stored text ends here \u{B7} time or output limit"),
        ("output_ceiling", "Stored text ends here \u{B7} time or output limit"),
        ("something_new", "Stored text ends here")
    ])
    func givenATruncatedPatch_whenBuilt_thenTheTailNamesTheCause(reason: String, tail: String) throws {
        // given
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: Data(ChangesJSON.sampleDiff.utf8), state: "truncated", reason: reason)

        // when
        let result = try model(TaskChangesDiffBuilder.build(patch: patch, header: header, facts: plainFacts))

        // then
        #expect(result.tail == tail)
        #expect(TaskChangesDiffBuilder.tail(patch.content) == tail)
    }

    @Test func givenAnAvailablePatch_whenTheTailIsAsked_thenThereIsNone() throws {
        // given
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: Data(ChangesJSON.sampleDiff.utf8))
        // when / then
        #expect(TaskChangesDiffBuilder.tail(patch.content) == nil)
    }

    @Test func givenAWorkingTreeRow_whenBuilt_thenTheSeparateObservationsCaptionShows() throws {
        // given
        let facts = TaskChangesRowFacts(path: "a", scopeTitle: "Working tree", hasText: true, label: nil, stateHelp: nil, countsAndPatchSeparate: true)
        let patch = try ChangesJSON.patch(ChangesJSON.selector("a", scope: .workingTree), bytes: Data(ChangesJSON.sampleDiff.utf8))

        // when
        let result = try model(TaskChangesDiffBuilder.build(patch: patch, header: TaskChangesDiffHeader(path: "a", scope: "Working tree"), facts: facts))

        // then
        #expect(result.caption == "Counts and patch for this scope are separate observations and can differ.")
        #expect(result.header.scope == "Working tree")
    }

    // MARK: Failures

    @Test func givenEachFailure_whenClassified_thenReloadClientBoundAndOtherAreTold() {
        // given / when / then
        #expect(TaskChangesDiffBuilder.classify(.failed(ChangesJSON.entryNotFound)) == .reload)
        #expect(TaskChangesDiffBuilder.classify(.failed(ChangesJSON.cursorExpired)) == .reload)
        #expect(TaskChangesDiffBuilder.classify(.clientBound(.deadline)) == .clientBound)
        #expect(TaskChangesDiffBuilder.classify(.clientBound(.requestBudget)) == .clientBound)
        #expect(TaskChangesDiffBuilder.classify(.failed(ChangesJSON.cursorInvalid)) == .other)
        #expect(TaskChangesDiffBuilder.classify(.failed(ChangesJSON.pageTooLarge)) == .other)
        #expect(TaskChangesDiffBuilder.classify(.failed(.timedOut(tool: "harflow-ctl", seconds: 30))) == .other)
        #expect(TaskChangesDiffBuilder.classify(.failed(.unsupportedCommand(tool: "harflow-ctl", command: "task-changes", detail: ""))) == .other)
        #expect(TaskChangesDiffBuilder.classify(.superseded) == .other)
    }

    @Test func givenEachFailureKind_whenItsNoteIsBuilt_thenTheTitleDetailAndActionFollowThePlan() {
        // given / when
        let reload = TaskChangesDiffBuilder.Failure.reload.note
        let bound = TaskChangesDiffBuilder.Failure.clientBound.note
        let other = TaskChangesDiffBuilder.Failure.other.note

        // then
        #expect(TaskChangesDiffBuilder.failureTitle == "This diff couldn't be read")
        #expect([reload.title, bound.title, other.title] == Array(repeating: "This diff couldn't be read", count: 3))
        #expect(reload.action == .reloadChanges && reload.action?.title == "Reload changes")
        #expect(bound.action == .retryDiff && bound.action?.title == "Retry")
        #expect(bound.detail == TaskChangesFailure.clientBoundSentence)
        #expect(other.action == .retryDiff)
        #expect(other.detail == "The engine did not give the stored text. No diff is implied.")
        #expect(reload.detail?.contains("Reload the list") == true)
    }

    // MARK: Descriptions

    @Test func givenAnyDiffValue_whenPrinted_thenNoDiffTextAppears() throws {
        // given
        let secret = "SECRET-LINE-CONTENT"
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: Data("@@ -1 +1 @@\n+\(secret)\n".utf8))
        let presentation = TaskChangesDiffBuilder.build(patch: patch, header: header, facts: plainFacts)
        let built = try model(presentation)

        // when
        let printed = [
            String(describing: presentation), String(reflecting: presentation), String(describing: built), String(reflecting: built),
            String(describing: built.text), String(reflecting: built.text), String(describing: patch),
            "\(TaskChangesDiffPresentation.loading(header))", String(describing: UnifiedDiffLines.classify("@@ -1 +1 @@\n+\(secret)\n"))
        ]

        // then
        for text in printed {
            #expect(!text.contains(secret), "\(text)")
        }
        #expect(String(describing: presentation) == "diff(2 lines)")
        #expect(built.drawnLines.contains("+" + secret), "the text is in the drawn string and nowhere that prints")
        #expect(String(describing: built.text) == "TaskChangesDiffText(2 lines)")
    }

    @Test func givenEachPresentationCase_whenDescribed_thenItNamesOnlyTheCase() {
        // given
        let note = TaskChangesDiffBuilder.Failure.other.note
        // when / then
        #expect(String(describing: TaskChangesDiffPresentation.none) == "none")
        #expect(String(describing: TaskChangesDiffPresentation.loading(header)) == "loading")
        #expect(String(describing: TaskChangesDiffPresentation.noText(header, label: "Binary")) == "noText")
        #expect(String(describing: TaskChangesDiffPresentation.failure(header, note)) == "failure")
    }

    // MARK: Line endings, equality and the drawn text

    @Test func givenCRLFLines_whenBuilt_thenTheCRLFNoticeShowsOnceAndNoLineCarriesACarriageReturn() throws {
        // given
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: Data("@@ -1 +1 @@\r\n-a\r\n+b\r\n".utf8))

        // when
        let result = try model(TaskChangesDiffBuilder.build(patch: patch, header: header, facts: plainFacts))

        // then
        #expect(result.lineEndingNotice == "Lines end in CRLF")
        #expect(TaskChangesDiffBuilder.crlfNotice == "Lines end in CRLF")
        #expect(result.drawnLines == ["@@ -1 +1 @@", "-a", "+b"])
    }

    @Test func givenHostileCharacters_whenBuilt_thenTheDrawnTextIsVisiblyEscaped() throws {
        // given
        let text = "@@ -1 +1 @@\n+a\u{202E}b\u{200B}c\u{1B}d\u{7F}e\tf\\g\n"
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: Data(text.utf8))

        // when
        let result = try model(TaskChangesDiffBuilder.build(patch: patch, header: header, facts: plainFacts))

        // then
        #expect(result.drawnLines.last == "+a\\u{202E}b\\u{200B}c\\x1bd\\x7fe\tf\\g")
    }

    @Test func givenTheSamePatchAndPath_whenBuiltTwice_thenTheDiffsAreEqualByIdentity() throws {
        // given
        let address = ChangesJSON.selector("src/app.py")
        let one = try ChangesJSON.patch(address, bytes: Data(ChangesJSON.sampleDiff.utf8))
        let two = try ChangesJSON.patch(address, bytes: Data(ChangesJSON.sampleDiff.utf8))
        let other = try ChangesJSON.patch(address, bytes: Data((ChangesJSON.sampleDiff + "+z\n").utf8))

        // when
        let first = TaskChangesDiffBuilder.build(patch: one, header: header, facts: plainFacts)
        let second = TaskChangesDiffBuilder.build(patch: two, header: header, facts: plainFacts)
        let different = TaskChangesDiffBuilder.build(patch: other, header: header, facts: plainFacts)

        // then
        #expect(first == second)
        #expect(first != different)
        #expect(try model(first).text.identity == model(second).text.identity)
    }

    @Test func givenTheSamePatchUnderAnotherPath_whenBuilt_thenTheIdentityDiffers() throws {
        // given
        let patch = try ChangesJSON.patch(ChangesJSON.selector("src/app.py"), bytes: Data(ChangesJSON.sampleDiff.utf8))
        // when
        let one = try model(TaskChangesDiffBuilder.build(patch: patch, header: header, facts: plainFacts))
        let two = try model(TaskChangesDiffBuilder.build(patch: patch, header: TaskChangesDiffHeader(path: "other.py", scope: "Committed"), facts: plainFacts))
        // then
        #expect(one.text.identity != two.text.identity)
    }

    @Test func givenACancelledTask_whenTheTextIsBuilt_thenThereIsNoText() async {
        // given
        let lines = UnifiedDiffLines.classify(ChangesJSON.sampleDiff)
        let task = Task { () -> TaskChangesDiffText? in
            while !Task.isCancelled { await Task.yield() }
            return TaskChangesDiffText.build(lines: lines, identity: 1)
        }

        // when
        task.cancel()
        let result = await task.value

        // then
        #expect(result == nil)
    }

    @Test func givenTheDrawnText_whenSized_thenTheContentHeightFollowsTheLineCount() throws {
        // given
        let text = try #require(TaskChangesDiffText.build(lines: UnifiedDiffLines.classify(ChangesJSON.sampleDiff), identity: 1))
        // when / then
        #expect(text.lineCount == 6)
        #expect(text.contentHeight == CGFloat(6) * TaskChangesDiffText.lineHeight + 2 * TaskChangesDiffText.verticalInset)
    }

    @Test func givenTheKinds_whenFillsAreLooked_thenOnlyAddedRemovedHunkAndMetaAreFilled() {
        // given
        let filled = Set(TaskChangesDiffText.fills.keys)
        // when / then
        #expect(filled == Set([UnifiedDiffLines.Kind.added, .removed, .hunk, .meta].map(\.code)))
        #expect(!filled.contains(UnifiedDiffLines.Kind.context.code) && !filled.contains(UnifiedDiffLines.Kind.noNewline.code))
        #expect(Set([UnifiedDiffLines.Kind.meta, .hunk, .added, .removed, .context, .noNewline].map(\.code)).count == 6)
    }

    @Test func givenDiffSafeText_whenEscaped_thenOnlyControlsAndFormatCharactersChange() {
        // given / when / then
        #expect(TaskChangesDisplayText.diffSafe("plain caf\u{E9} \\ \t \u{65E5}") == "plain caf\u{E9} \\ \t \u{65E5}")
        #expect(TaskChangesDisplayText.diffSafe("\u{0}\u{1F}\u{7F}") == "\\x00\\x1f\\x7f")
        #expect(TaskChangesDisplayText.diffSafe("\u{85}") == "\\u{0085}")
        #expect(TaskChangesDisplayText.diffSafe("\u{202A}\u{2066}\u{2028}\u{2029}\u{FEFF}") == "\\u{202A}\\u{2066}\\u{2028}\\u{2029}\\u{FEFF}")
    }
}
