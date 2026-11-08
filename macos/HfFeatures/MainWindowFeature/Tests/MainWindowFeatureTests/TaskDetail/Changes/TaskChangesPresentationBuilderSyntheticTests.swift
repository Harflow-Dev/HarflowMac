import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskChangesPresentationBuilderSyntheticTests

/// Cases the vendored fixtures do not cover: counts, copy gating, names, rows and unknown states.
struct TaskChangesPresentationBuilderSyntheticTests {

    private func built(_ repositories: [JSONValue], capture: (state: String, reason: String?) = ("available", nil)) throws -> TaskChangesBuilt {
        TaskChangesPresentationBuilder.built(try ChangesJSON.snapshot(ChangesJSON.page(capture: capture, repositories: repositories, limit: 500), limit: 500))
    }

    private func repository(_ built: TaskChangesBuilt, _ index: Int = 0) throws -> TaskChangesRepositoryModel {
        try #require(built.document?.repositories[index])
    }

    // MARK: Tab count

    @Test func givenAnAvailableCaptureWithRows_whenBuilt_thenTheTabCountIsTheSumOfStoredRowCounts() throws {
        // given
        let first = ChangesJSON.repository(committed: ChangesJSON.committed(rows: ChangesJSON.rows(2)),
                                           working: ChangesJSON.working(rows: ChangesJSON.rows(1, prefix: "w")))
        let second = ChangesJSON.repository(root: "/other/two", committed: ChangesJSON.committed(rows: ChangesJSON.rows(4)))
        // when
        let result = try built([first, second])
        // then
        #expect(result.tabCount == 7)
    }

    @Test func givenACompleteCaptureOfZeroRows_whenBuilt_thenTheTabCountIsZeroAndTheCaptionShows() throws {
        // given / when
        let result = TaskChangesPresentationBuilder.built(try ChangesJSON.zeroRows())
        // then
        #expect(result.tabCount == 0)
        #expect(result.document?.caption == TaskChangesPresentationBuilder.completeCaption)
        let scopes = try #require(result.document?.repositories.first?.scopes)
        #expect(scopes.map(\.captions) == [[TaskChangesPresentationBuilder.noDifferences], [TaskChangesPresentationBuilder.noDifferences]])
        #expect(scopes.map(\.count) == ["0", "0"])
    }

    @Test func givenUnmergedUnknownOnAnAvailableCapture_whenBuilt_thenTheTabCountStillSumsBecauseItNeverUsesCompleteness() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rows: ChangesJSON.rows(2)),
                                          working: ChangesJSON.working(rows: ChangesJSON.rows(1, prefix: "w"), unmergedUnknown: true))
        let snapshot = try ChangesJSON.snapshot(ChangesJSON.page(repositories: [repo]))
        // when
        let result = TaskChangesPresentationBuilder.built(snapshot)
        // then
        #expect(!snapshot.completeness.isComplete)
        #expect(result.tabCount == 3)
    }

    @Test func givenAnAvailableCaptureWithACaptureReason_whenBuilt_thenTheTabCountStillSums() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rows: ChangesJSON.rows(2)))
        // when
        let result = try built([repo], capture: ("available", "some_future_note"))
        // then
        #expect(result.tabCount == 2)
        #expect(result.document?.banner?.reason == "some_future_note: Reason not recognised by this version.")
    }

    @Test func givenAnyDisqualifyingState_whenBuilt_thenThereIsNoTabCount() throws {
        // given
        let rows = ChangesJSON.rows(2)
        let truncated = ChangesJSON.repository(committed: ChangesJSON.committed(rowCount: 500, rows: ChangesJSON.rows(500), truncated: true))
        let notCapturedScope = ChangesJSON.repository(committed: ChangesJSON.committed(rows: rows),
                                                      working: ChangesJSON.working(state: "not_captured", reason: "git_failed"))
        let incompleteScope = ChangesJSON.repository(committed: ChangesJSON.committed(state: "incomplete", reason: "output_ceiling", rows: rows))
        let incompleteRepository = ChangesJSON.repository(state: "incomplete", reason: "capture_timeout", committed: ChangesJSON.committed(rows: rows))
        let unavailableRepository = ChangesJSON.repository(state: "unavailable", reason: "git_failed", committed: nil, working: nil)
        let unknownRepository = ChangesJSON.repository(state: "mystery", committed: nil, working: nil)
        let unknownScope = ChangesJSON.repository(committed: ChangesJSON.committed(state: "mystery"))

        // when / then
        for (name, repo) in [("truncated", truncated), ("not captured scope", notCapturedScope), ("incomplete scope", incompleteScope),
                             ("incomplete repository", incompleteRepository), ("unavailable repository", unavailableRepository),
                             ("unknown repository", unknownRepository), ("unknown scope", unknownScope)] {
            #expect(try built([repo]).tabCount == nil, "\(name)")
        }
        #expect(try built([ChangesJSON.repository()], capture: ("incomplete", "capture_timeout")).tabCount == nil)
        #expect(try built([ChangesJSON.repository(), unavailableRepository]).tabCount == nil, "one bad repository disqualifies all")
    }

    // MARK: Scope and repository counts

    @Test func givenARowLimitedScope_whenBuilt_thenItReadsFiveHundredPlusWithTheRowLimitTag() throws {
        // given
        let wanted = ChangesJSON.rows(3, prefix: "w")
        let firstRepo = ChangesJSON.repository(committed: ChangesJSON.committed(rowCount: 500, rows: ChangesJSON.rows(500), truncated: true),
                                               working: ChangesJSON.working(rowCount: 3))
        let secondRepo = ChangesJSON.repository(committed: ChangesJSON.committed(rowCount: 500, truncated: true),
                                                working: ChangesJSON.working(rows: wanted))
        let snapshot = try ChangesJSON.snapshot([(ChangesJSON.page(repositories: [firstRepo], limit: 500, cursor: "next"), 500),
                                                 (ChangesJSON.page(repositories: [secondRepo], limit: 500), 500)])
        // when
        let model = try #require(TaskChangesPresentationBuilder.built(snapshot).document?.repositories.first)
        // then
        let committed = try #require(model.scopes.first)
        #expect(committed.count == "500+")
        #expect(committed.tag == TaskChangesTag(text: "Row limit \u{B7} 500 of more", tone: .warn))
        #expect(model.tag == TaskChangesTag(text: "Row limit", tone: .warn))
        #expect(model.count == "503+", "a repository count sums its scopes and takes the plus")
    }

    @Test func givenAnIncompleteScopeWithoutRows_whenBuilt_thenItReadsZeroPlus() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(state: "incomplete", reason: "output_ceiling"))
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.scopes.first?.count == "0+")
        #expect(model.scopes.first?.tag == TaskChangesTag(text: "Incomplete \u{B7} output limit", tone: .warn))
        #expect(model.count == "0+")
    }

    @Test func givenRepositoryCountsWithAndWithoutAPlus_whenBuilt_thenTheyAddWithPlusWhenAnyScopeHasOne() throws {
        // given
        let plain = ChangesJSON.repository(committed: ChangesJSON.committed(rows: ChangesJSON.rows(2)),
                                           working: ChangesJSON.working(rows: ChangesJSON.rows(1, prefix: "w")))
        let incompleteScope = ChangesJSON.committed(state: "incomplete", reason: "capture_timeout", rows: ChangesJSON.rows(2))
        let withPlus = ChangesJSON.repository(root: "/x/other", committed: incompleteScope,
                                              working: ChangesJSON.working(rows: ChangesJSON.rows(1, prefix: "w")))
        // when
        let result = try built([plain, withPlus])
        // then
        #expect(try repository(result, 0).count == "3")
        #expect(try repository(result, 1).count == "3+")
        #expect(try repository(result, 1).tag == TaskChangesTag(text: "Incomplete", tone: .warn))
    }

    @Test func givenANotCapturedScope_whenBuilt_thenItReadsADashAndTheRepositoryNamesIt() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rows: ChangesJSON.rows(2)),
                                          working: ChangesJSON.working(state: "not_captured", reason: "git_failed"))
        // when
        let model = try repository(try built([repo]))
        // then
        let working = try #require(model.scopes.last)
        #expect(working.count == "\u{2014}")
        #expect(working.tag == TaskChangesTag(text: "Not captured", tone: .warn))
        #expect(working.captions == [TaskChangesReasons.sentence(for: "git_failed")])
        #expect(model.tag == TaskChangesTag(text: "Working tree not captured", tone: .warn))
        #expect(model.count == "2")
    }

    @Test(arguments: [
        ("repository_identity_changed", "Identity changed"), ("alternates_present", "Alternates present"),
        ("object_store_untrusted", "Object store untrusted"), ("head_missing", "Not captured")
    ])
    func givenANotCapturedRepository_whenBuilt_thenItHasItsTagNoCountAndNoScopes(reason: String, tag: String) throws {
        // given
        let repo = ChangesJSON.repository(state: "not_captured", reason: reason, committed: nil, working: nil)
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.tag == TaskChangesTag(text: tag, tone: .warn))
        #expect(model.count == nil)
        #expect(model.scopes.isEmpty)
        #expect(model.notes.first?.title == TaskChangesReasons.sentence(for: reason))
    }

    @Test func givenAnIncompleteRepositoryThatNeverStarted_whenBuilt_thenItHasNoCount() throws {
        // given
        let repo = ChangesJSON.repository(state: "incomplete", reason: "budget_exhausted", committed: nil, working: nil)
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.tag == TaskChangesTag(text: "Not started \u{B7} budget used", tone: .warn))
        #expect(model.count == nil)
    }

    @Test func givenAnUnavailableRepository_whenBuilt_thenItIsTaggedWithoutACount() throws {
        // given
        let repo = ChangesJSON.repository(state: "unavailable", reason: "repository_unavailable", committed: nil, working: nil)
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.tag == TaskChangesTag(text: "Unavailable", tone: .warn))
        #expect(model.count == nil)
    }

    // MARK: Empty-scope copy gating

    @Test func givenUnmergedUnknown_whenAnEmptyScopeIsBuilt_thenItUsesTheConflictsUnknownCopyAndTheOtherScopeClaimsNothing() throws {
        // given
        let repo = ChangesJSON.repository(working: ChangesJSON.working(unmergedUnknown: true))
        // when
        let model = try repository(try built([repo]))
        // then
        let working = try #require(model.scopes.last)
        #expect(working.captions == [TaskChangesPresentationBuilder.conflictsNotExamined])
        #expect(working.captions.first == "No rows in this scope. Conflicts were not examined, so this is not a clean bill.")
        #expect(working.tag == TaskChangesTag(text: "Conflicts unknown", tone: .warn))
        #expect(model.scopes.first?.captions == [TaskChangesPresentationBuilder.noRows])
        #expect(model.tag == TaskChangesTag(text: "Conflicts unknown", tone: .warn))
        let note = try #require(model.notes.first)
        #expect(note.title == "Conflicts may exist" && note.tone == .warn)
    }

    @Test func givenReportedConflictNames_whenAnEmptyScopeIsBuilt_thenItClaimsNoDifferencesNoMoreAndShowsTheInfoNoteAndTag() throws {
        // given
        let repo = ChangesJSON.repository(working: ChangesJSON.working(conflicts: ["a.txt"]))
        // when
        let result = try built([repo])
        let model = try repository(result)
        // then
        let working = try #require(model.scopes.last)
        #expect(working.captions == [TaskChangesPresentationBuilder.noRows])
        #expect(model.scopes.first?.captions == [TaskChangesPresentationBuilder.noRows], "conflicts in any scope withdraw the clean bill")
        #expect(working.tag == TaskChangesTag(text: "Reported conflict", tone: .info))
        #expect(model.tag == TaskChangesTag(text: "Reported conflict", tone: .info))
        #expect(model.notes.map(\.title) == ["Conflicts may exist"])
        #expect(model.notes.first?.tone == .info)
        #expect(result.document?.caption == nil, "reported names disqualify the complete-capture caption")
    }

    @Test func givenCutOffConflictNames_whenBuilt_thenTheyCountAsReported() throws {
        // given
        let repo = ChangesJSON.repository(working: ChangesJSON.working(conflictsTruncated: true))
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.scopes.last?.tag == TaskChangesTag(text: "Reported conflict", tone: .info))
        #expect(model.scopes.last?.captions == [TaskChangesPresentationBuilder.noRows])
    }

    @Test func givenAnEmptyScopeInAnIncompleteRepository_whenBuilt_thenItClaimsNothingAboutCompleteness() throws {
        // given
        let repo = ChangesJSON.repository(state: "incomplete", reason: "capture_timeout")
        // when
        let model = try repository(try built([repo], capture: ("incomplete", "capture_timeout")))
        // then
        #expect(model.scopes.map(\.captions) == [[TaskChangesPresentationBuilder.noRows], [TaskChangesPresentationBuilder.noRows]])
    }

    @Test func givenAnEmptyScopeInATruncatedSiblingRepository_whenBuilt_thenItIsNotACleanBill() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rowCount: 500, rows: ChangesJSON.rows(500), truncated: true))
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.scopes.last?.captions == [TaskChangesPresentationBuilder.noRows])
    }

    @Test func givenADirtyBaseline_whenAWorkingTreeHasRows_thenTheCaptionAddsThatItWasAlreadyDirty() throws {
        // given
        let repo = ChangesJSON.repository(baselineDirty: .bool(true), working: ChangesJSON.working(rows: ChangesJSON.rows(1)))
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.scopes.last?.captions == [TaskChangesPresentationBuilder.workingTreeCaption + " It was already dirty when this task started."])
        #expect(model.facts.last == TaskChangesFact(term: "Started dirty", value: "Yes"))
    }

    // MARK: Multiple repositories and names

    @Test func givenManyRepositories_whenBuilt_thenOnlyTheFirstStartsOpenAndNamesFallBack() throws {
        // given
        let one = ChangesJSON.repository(root: "/work/alpha")
        let none = ChangesJSON.repository(root: nil)
        let three = ChangesJSON.repository(root: "/work/gamma")
        // when
        let result = try built([one, none, three])
        // then
        let models = try #require(result.document?.repositories)
        #expect(models.map(\.startsOpen) == [true, false, false])
        #expect(models.map(\.name) == ["alpha", "Repository 2", "gamma"])
        #expect(models[1].help == nil)
        #expect(models.map(\.id) == [0, 1, 2])
    }

    @Test func givenRepeatedNames_whenNamed_thenTheLastTwoComponentsAreUsed() throws {
        // given
        let entries = try ChangesJSON.entries([
            ChangesJSON.repository(root: "/a/app"), ChangesJSON.repository(root: "/b/app"), ChangesJSON.repository(root: "/c/unique")
        ])
        // when
        let names = TaskChangesPresentationBuilder.repositoryNames(entries)
        // then
        #expect(names == ["a/app", "b/app", "unique"])
    }

    @Test func givenARootWithControlsAndACutRoot_whenNamed_thenNamesAreEscapedAndCutOnesEndWithAnEllipsis() throws {
        // given
        let cutRoot = "/work/" + String(repeating: "x", count: 4082)
        let entries = try ChangesJSON.entries([
            ChangesJSON.repository(root: "/work/re\u{202E}po"), ChangesJSON.repository(root: cutRoot, fieldsTruncated: true)
        ])
        // when
        let names = TaskChangesPresentationBuilder.repositoryNames(entries)
        // then
        #expect(names[0] == "re\\u{202E}po")
        #expect(names[1] == String(repeating: "x", count: 4082) + "\u{2026}", "a root within 12 bytes of the 4096 bound was cut")
    }

    @Test func givenASlashOnlyRoot_whenNamed_thenTheRootItselfIsTheName() throws {
        // given
        let entries = try ChangesJSON.entries([ChangesJSON.repository(root: "/")])
        // when / then
        #expect(TaskChangesPresentationBuilder.repositoryNames(entries) == ["/"])
    }

    @Test func givenAHostileRoot_whenBuilt_thenTheHelpTextIsEscaped() throws {
        // given
        let repo = ChangesJSON.repository(root: "/work/a\\b")
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.help == "/work/a\\\\b")
    }

    // MARK: Provenance

    @Test func givenTruncatedFields_whenBuilt_thenRowsAreDimmedAndTheFactsSayValuesWereCut() throws {
        // given
        let repo = ChangesJSON.repository(fieldsTruncated: true, committed: ChangesJSON.committed(rows: ChangesJSON.rows(1)))
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(!model.name.hasSuffix("\u{2026}"), "another cut field does not mark the repository name")
        #expect(model.facts.last == TaskChangesFact(term: "Note", value: "Some of these values were cut."))
        #expect(model.scopes.first?.rows.allSatisfy(\.isDimmed) == true)
    }

    @Test func givenARepositoryWithoutARoot_whenBuilt_thenItsRowsAreDimmed() throws {
        // given
        let repo = ChangesJSON.repository(root: nil, committed: ChangesJSON.committed(rows: ChangesJSON.rows(1)))
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.scopes.first?.rows.first?.isDimmed == true)
    }

    @Test(arguments: [
        (JSONValue.string("unknown"), "Unknown"), (.string("surprising"), "surprising"), (.bool(false), "No"), (.bool(true), "Yes")
    ])
    func givenABaselineDirtyValue_whenBuilt_thenTheFactReadsIt(value: JSONValue, text: String) throws {
        // given
        let repo = ChangesJSON.repository(baselineDirty: value)
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.facts.last == TaskChangesFact(term: "Started dirty", value: text))
    }

    // MARK: Rows

    @Test func givenRowKinds_whenBuilt_thenLettersLabelsAndHelpFollowThePinTable() throws {
        // given
        let rows = [
            ChangesJSON.row("a", status: "deleted", additions: 0, deletions: 3),
            ChangesJSON.row("b", status: "typechange"),
            ChangesJSON.row("c", status: "unmerged", additions: nil, deletions: nil, content: "not_captured", reason: "unmerged"),
            ChangesJSON.row("d", status: "submodule", additions: nil, deletions: nil, content: "not_captured", reason: "submodule"),
            ChangesJSON.row("e", status: "untracked", additions: nil, deletions: nil, content: "not_captured", reason: "untracked"),
            ChangesJSON.row("build/", status: "untracked", additions: nil, deletions: nil, content: "not_captured", reason: "untracked"),
            ChangesJSON.row("g", content: "truncated", reason: "file_limit"),
            ChangesJSON.row("h", content: "truncated", reason: "task_limit"),
            ChangesJSON.row("i", content: "omitted_size", reason: "task_limit"),
            ChangesJSON.row("j", content: "truncated", reason: "output_ceiling"),
            ChangesJSON.row("k", content: "truncated", reason: nil),
            ChangesJSON.row("l", content: "not_captured", reason: nil),
            ChangesJSON.row("m", binary: true, content: "binary")
        ]
        // when
        let model = try repository(try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: rows))]))

        // then
        let scoped = try #require(model.scopes.first?.rows)
        #expect(scoped.map(\.letter) == ["D", "T", "U", "S", "?", "?", "M", "M", "M", "M", "M", "M", "M"])
        #expect(scoped.map(\.state) == [nil, nil, "Unmerged \u{B7} no text", "Submodule \u{B7} no text", "Name only", "Directory \u{B7} name only",
                                         "Truncated \u{B7} over 64 KiB", "Partial text \u{B7} task limit", "Text omitted \u{B7} task limit",
                                         "Truncated \u{B7} time or output limit", "Truncated", "Not captured", "Binary"])
        #expect(scoped[5].path == "build/")
        #expect(scoped[6].stateHelp == TaskChangesReasons.rowSentence(state: "truncated", reason: "file_limit"))
        #expect(scoped[7].stateHelp == TaskChangesReasons.rowSentence(state: "truncated", reason: "task_limit"))
        #expect(scoped[1].stateHelp == nil, "an ordinary row carries no hover help")
        #expect(scoped[0].additions == 0 && scoped[0].deletions == 3)
    }

    @Test func givenANonUTF8Path_whenBuilt_thenItIsEscapedLabelledAndStillAddressable() throws {
        // given
        let row = ChangesJSON.row(encoded: Data([0x61, 0xFF, 0x62]))
        // when
        let model = try repository(try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))]))
        // then
        let shown = try #require(model.scopes.first?.rows.first)
        #expect(shown.path == "a\\xffb")
        #expect(shown.state == "Bytes, not UTF-8")
        #expect(!shown.isDimmed)
    }

    @Test func givenACutPath_whenBuilt_thenTheRowIsLabelledNoTextAndDimmed() throws {
        // given
        let row = ChangesJSON.row("long/cut", pathTruncated: true, additions: nil, deletions: nil, content: "not_captured", reason: "path_too_long")
        // when
        let model = try repository(try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))]))
        // then
        let shown = try #require(model.scopes.first?.rows.first)
        #expect(shown.state == "Path cut \u{B7} no text")
        #expect(shown.stateHelp == TaskChangesReasons.sentence(for: "path_too_long"))
        #expect(shown.isDimmed)
    }

    @Test func givenAPathWithControlsAndBackslashes_whenBuilt_thenThePathIsEscaped() throws {
        // given
        let row = ChangesJSON.row("dir\\a\u{202E}b\nc.txt")
        // when
        let model = try repository(try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))]))
        // then
        #expect(model.scopes.first?.rows.first?.path == "dir\\\\a\\u{202E}b\\x0ac.txt")
    }

    @Test func givenUnknownStatusAndContentState_whenBuilt_thenTheRawValuesShowWithAMiddleDotLetter() throws {
        // given
        let row = ChangesJSON.row("a", status: "renamed", content: "exotic")
        // when
        let model = try repository(try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))]))
        // then
        let shown = try #require(model.scopes.first?.rows.first)
        #expect(shown.letter == "\u{B7}")
        #expect(shown.statusWord == "renamed")
        #expect(shown.state == "exotic")
        #expect(shown.stateHelp == TaskChangesReasons.unrecognisedState)
        #expect(shown.additions == nil && shown.deletions == nil, "an unknown content state shows no counts")
    }

    @Test func givenMoreRowsThanOneRevealStep_whenBuilt_thenEveryRowIsKeptForTheViewToReveal() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rows: ChangesJSON.rows(450)))
        let snapshot = try ChangesJSON.snapshot(ChangesJSON.page(repositories: [repo], limit: 500), limit: 500)
        // when
        let model = try #require(TaskChangesPresentationBuilder.built(snapshot).document?.repositories.first)
        // then
        #expect(TaskChangesPresentationBuilder.revealStep == 200)
        #expect(model.scopes.first?.rows.count == 450)
        #expect(model.scopes.first?.count == "450")
        #expect(model.scopes.first?.rows.map(\.id) == Array(0 ..< 450))
    }

    @Test func givenTheSamePathInBothScopes_whenBuilt_thenBothScopesShowARow() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rows: [ChangesJSON.row("same.txt")]),
                                          working: ChangesJSON.working(rows: [ChangesJSON.row("same.txt")]))
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.scopes.map { $0.rows.map(\.path) } == [["same.txt"], ["same.txt"]])
        #expect(model.scopes.map(\.id.scope) == ["committed_range", "working_tree"])
    }

    // MARK: Unknown states

    @Test func givenAnUnknownCaptureState_whenBuilt_thenTheRawStateShowsWithNoCount() throws {
        // given
        let snapshot = try ChangesJSON.captureOnly(task: "t1", state: "mystery", reason: nil)
        // when
        let result = TaskChangesPresentationBuilder.built(snapshot)
        // then
        let note = try #require(result.note)
        #expect(note.reason == "mystery: State not recognised by this version.")
        #expect(note.action == .retryRead)
        #expect(result.tabCount == nil)
    }

    @Test func givenAnUnknownRepositoryState_whenBuilt_thenItShowsRawWithNoCountAndNoScopes() throws {
        // given
        let repo = ChangesJSON.repository(state: "mystery", committed: nil, working: nil)
        // when
        let model = try repository(try built([repo]))
        // then
        #expect(model.tag == TaskChangesTag(text: "mystery", tone: .warn))
        #expect(model.count == nil)
        #expect(model.scopes.isEmpty)
        #expect(model.notes.first?.title == "mystery: State not recognised by this version.")
    }

    @Test func givenAnUnknownScopeState_whenBuilt_thenItShowsRawWithNoCountAndTheSentence() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(state: "mystery"))
        // when
        let model = try repository(try built([repo]))
        // then
        let scope = try #require(model.scopes.first)
        #expect(scope.count == nil)
        #expect(scope.tag == TaskChangesTag(text: "mystery", tone: .warn))
        #expect(scope.captions == ["mystery: State not recognised by this version."])
        #expect(model.count == "0", "the unrecognised scope adds nothing, so only the working tree counts")
    }

    @Test func givenAnAvailableCaptureWithNoRepositoriesAndNoReason_whenBuilt_thenItIsTheNoRepositoriesNote() throws {
        // given / when
        let result = try built([])
        // then
        #expect(result.note?.title == "No repositories listed")
        #expect(result.tabCount == nil)
    }

    @Test func givenAPendingCaptureWithAnUnknownReason_whenBuilt_thenItIsNotSettlingAndShowsTheRawReason() throws {
        // given
        let snapshot = try ChangesJSON.captureOnly(task: "t1", state: "pending", reason: "queued_elsewhere")
        // when
        let result = TaskChangesPresentationBuilder.built(snapshot)
        // then
        #expect(!result.isSettling)
        #expect(result.note?.reason == "queued_elsewhere: Reason not recognised by this version.")
    }

    // MARK: Observed time

    @Test func givenAnISOTimeAndGarbage_whenFormatted_thenTheTimeIsLocalisedAndGarbageIsEscaped() {
        // given / when
        let formatted = TaskChangesPresentationBuilder.observedText("2026-10-14T17:45:50+00:00")
        let garbage = TaskChangesPresentationBuilder.observedText("not\u{202E}a time")
        // then
        #expect(formatted.contains("2026") && !formatted.contains("T17"))
        #expect(garbage == "not\\u{202E}a time")
    }

    // MARK: Count caption and incomplete repositories

    @Test func givenOneRepositoryWithDistinctPaths_whenBuilt_thenThereIsNoCountCaption() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rows: [ChangesJSON.row("a.txt")]),
                                          working: ChangesJSON.working(rows: [ChangesJSON.row("b.txt")]))
        // when
        let result = try built([repo])
        // then
        #expect(result.document?.countCaption == nil)
    }

    @Test func givenAPathInBothScopes_whenBuilt_thenTheCountCaptionShows() throws {
        // given
        let repo = ChangesJSON.repository(committed: ChangesJSON.committed(rows: [ChangesJSON.row("same.txt")]),
                                          working: ChangesJSON.working(rows: [ChangesJSON.row("same.txt")]))
        // when
        let result = try built([repo])
        // then
        #expect(result.document?.countCaption == TaskChangesPresentationBuilder.countCaption)
        #expect(TaskChangesPresentationBuilder.countCaption
            == "The tab counts rows across repositories and scopes. A path in both scopes counts twice.")
    }

    @Test func givenSeveralRepositories_whenBuilt_thenTheCountCaptionShowsEvenWithoutSharedPaths() throws {
        // given
        let result = try built([ChangesJSON.repository(root: "/a/one"), ChangesJSON.repository(root: "/b/two")])
        // then
        #expect(result.document?.countCaption == TaskChangesPresentationBuilder.countCaption)
    }

    @Test func givenAnAvailableScopeInAnIncompleteRepository_whenBuilt_thenItsCountTakesAPlus() throws {
        // given
        let repo = ChangesJSON.repository(state: "incomplete", reason: "capture_timeout",
                                          committed: ChangesJSON.committed(rows: ChangesJSON.rows(2)))
        // when
        let model = try repository(try built([repo], capture: ("incomplete", "capture_timeout")))
        // then
        #expect(model.scopes.map(\.count) == ["2+", "0+"])
    }

    @Test func givenRootsNearTheBound_whenNamed_thenTheEllipsisNeedsTheFlagAndARootWithinTwelveBytesOfTheBound() throws {
        // given
        let nearly = "/" + String(repeating: "y", count: 4086)
        let short = "/" + String(repeating: "z", count: 4070)
        let entries = try ChangesJSON.entries([
            ChangesJSON.repository(root: nearly, fieldsTruncated: true),
            ChangesJSON.repository(root: nearly + "q", fieldsTruncated: false),
            ChangesJSON.repository(root: short, fieldsTruncated: true)
        ])
        // when
        let names = TaskChangesPresentationBuilder.repositoryNames(entries)
        // then
        #expect(names[0].hasSuffix("\u{2026}"), "flag set and root near the bound")
        #expect(!names[1].hasSuffix("\u{2026}"), "an intact root near the bound with the flag off is not marked")
        #expect(!names[2].hasSuffix("\u{2026}"), "flag set but the root is far from the bound")
    }
}
