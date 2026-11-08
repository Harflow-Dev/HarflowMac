import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskChangesPresentationBuilderRowFactsTests

/// What selecting a listed row needs: its selector, the facts keyed by it, and which states store text.
struct TaskChangesPresentationBuilderRowFactsTests {

    private func built(_ repositories: [JSONValue]) throws -> TaskChangesBuilt {
        TaskChangesPresentationBuilder.built(try ChangesJSON.snapshot(ChangesJSON.page(repositories: repositories)))
    }

    private func rows(_ built: TaskChangesBuilt) -> [TaskChangesRowModel] {
        built.document?.repositories.flatMap { $0.scopes.flatMap(\.rows) } ?? []
    }

    // MARK: Fixture

    @Test func givenTheAvailableListing_whenBuilt_thenEveryRowHasASelectorAndFactsKeyedByIt() throws {
        // given: ctl-task-changes-available-listing.json plus ctl-task-changes-listing-next-page.json
        let result = TaskChangesPresentationBuilder.built(try ChangesJSON.availableListing())

        // then
        #expect(result.isDocument)
        #expect(result.rowFacts.count == 6)
        let readme = try #require(result.rowFacts[ChangesJSON.selector("README.md")])
        #expect(readme == TaskChangesRowFacts(path: "README.md", scopeTitle: "Committed", hasText: true, label: nil, stateHelp: nil,
                                              countsAndPatchSeparate: false))
        let app = try #require(result.rowFacts[ChangesJSON.selector("src/app.py", scope: .workingTree)])
        #expect(app.scopeTitle == "Working tree" && app.countsAndPatchSeparate)
        let logo = try #require(result.rowFacts[ChangesJSON.selector("assets/logo.png")])
        #expect(!logo.hasText && logo.label == "Binary")
        let notes = try #require(result.rowFacts[ChangesJSON.selector("notes.txt", scope: .workingTree)])
        #expect(!notes.hasText && notes.label == "Name only")
        #expect(notes.stateHelp == TaskChangesReasons.rowSentence(state: "not_captured", reason: "untracked"))
    }

    @Test func givenThePathInBothScopes_whenBuilt_thenTheTwoSelectorsAreDistinctWithTheirOwnFacts() throws {
        // given: src/app.py is in committed_range and working_tree
        let result = TaskChangesPresentationBuilder.built(try ChangesJSON.availableListing())
        let committed = try #require(result.rowFacts[ChangesJSON.selector("src/app.py")])
        let working = try #require(result.rowFacts[ChangesJSON.selector("src/app.py", scope: .workingTree)])
        // then
        #expect(committed.scopeTitle == "Committed" && !committed.countsAndPatchSeparate)
        #expect(working.scopeTitle == "Working tree" && working.countsAndPatchSeparate)
        #expect(committed != working)
    }

    // MARK: Selector and dimming

    @Test func givenEveryRow_whenBuilt_thenTheSelectorIsNilExactlyWhenTheRowIsDimmed() throws {
        // given
        let cut = ChangesJSON.row("cut/path", pathTruncated: true, additions: nil, deletions: nil, content: "not_captured", reason: "path_too_long")
        let truncatedRepository = ChangesJSON.repository(root: "/a/one", fieldsTruncated: true, committed: ChangesJSON.committed(rows: [ChangesJSON.row("x")]))
        let noRoot = ChangesJSON.repository(root: nil, committed: ChangesJSON.committed(rows: [ChangesJSON.row("y")]))
        let fine = ChangesJSON.repository(root: "/b/two", committed: ChangesJSON.committed(rows: [ChangesJSON.row("z"), cut]))

        // when
        let result = try built([truncatedRepository, noRoot, fine])

        // then
        let all = rows(result)
        #expect(all.count == 4)
        #expect(all.allSatisfy { ($0.selector == nil) == $0.isDimmed })
        #expect(all.map(\.isDimmed) == [true, true, false, true])
        #expect(result.rowFacts.count == 1, "only the addressable row has facts")
    }

    @Test func givenARowSelector_whenRead_thenItCarriesTheRootScopeAndPathBytes() throws {
        // given
        let row = ChangesJSON.row(encoded: Data([0x61, 0xFF]))
        // when
        let result = try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))])
        // then
        let address = try #require(rows(result).first?.selector)
        #expect(address.repositoryRoot == "/workspace/repo")
        #expect(address.scope == .committedRange)
        #expect(address.pathBytes == Data([0x61, 0xFF]))
        #expect(result.rowFacts[address]?.path == "a\\xff")
    }

    // MARK: Text states

    @Test(arguments: [
        ("available", true), ("truncated", true), ("binary", false), ("omitted_size", false), ("not_captured", false), ("exotic", false)
    ])
    func givenAContentState_whenBuilt_thenTextIsStoredOnlyForAvailableAndTruncated(state: String, hasText: Bool) throws {
        // given
        let row = ChangesJSON.row("f", content: state, reason: state == "truncated" ? "file_limit" : nil)
        // when
        let result = try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))])
        // then
        let facts = try #require(result.rowFacts.values.first)
        #expect(facts.hasText == hasText)
    }

    @Test func givenARowWithoutStoredText_whenBuilt_thenTheFactsKeepTheLabelAndHelpForTheSelectedState() throws {
        // given
        let rows = [
            ChangesJSON.row("a", additions: nil, deletions: nil, binary: true, content: "binary"),
            ChangesJSON.row("b", content: "omitted_size", reason: "task_limit"),
            ChangesJSON.row("c", status: "submodule", content: "not_captured", reason: "submodule")
        ]
        // when
        let result = try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: rows))])
        // then
        let labels = Dictionary(uniqueKeysWithValues: result.rowFacts.values.map { ($0.path, $0.label) })
        #expect(labels == ["a": "Binary", "b": "Text omitted \u{B7} task limit", "c": "Submodule \u{B7} no text"])
    }

    // MARK: Document status

    @Test func givenNotesAndLoading_whenBuilt_thenThereAreNoRowFactsAndItIsNotADocument() throws {
        // given / when
        let note = TaskChangesPresentationBuilder.built(try ChangesJSON.pendingRunning())
        let failure = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.clientBound(.deadline)))
        let superseded = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.superseded))
        // then
        for result in [note, failure, superseded] {
            #expect(!result.isDocument)
            #expect(result.rowFacts.isEmpty)
        }
    }

    @Test func givenAnIncompleteCapture_whenBuilt_thenItIsStillADocumentWithFacts() throws {
        // given: ctl-task-changes-incomplete.json
        let result = TaskChangesPresentationBuilder.built(try ChangesJSON.incomplete())
        // then
        #expect(result.isDocument)
        let facts = try #require(result.rowFacts[ChangesJSON.selector("big.txt")])
        #expect(facts.hasText && facts.label == "Truncated \u{B7} time or output limit")
    }

    @Test func givenRepositoriesThatAreNotAvailable_whenBuilt_thenNoRowFactsAreKept() throws {
        // given
        let unavailable = ChangesJSON.repository(state: "unavailable", reason: "git_failed", committed: nil, working: nil)
        // when
        let result = try built([unavailable])
        // then
        #expect(result.isDocument && result.rowFacts.isEmpty)
    }

    // MARK: Fingerprint

    @Test func givenTheSameListingBuiltTwice_whenFingerprinted_thenTheFingerprintsMatch() throws {
        // given / when
        let first = TaskChangesPresentationBuilder.built(try ChangesJSON.availableListing())
        let second = TaskChangesPresentationBuilder.built(try ChangesJSON.availableListing())
        // then
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.fingerprint != 0)
    }

    @Test func givenAChangedByteCountAdditionOrStatus_whenFingerprinted_thenTheFingerprintChanges() throws {
        // given
        let base = TaskChangesPresentationBuilder.built(try ChangesJSON.availableListing()).fingerprint
        let bytes = TaskChangesPresentationBuilder.built(try ChangesJSON.availableListing(readmeBytes: 43)).fingerprint
        let additions = TaskChangesPresentationBuilder.built(try ChangesJSON.availableListing(readmeAdditions: 2)).fingerprint
        let status = TaskChangesPresentationBuilder.built(try snapshot(rowStatus: "modified")).fingerprint
        let original = TaskChangesPresentationBuilder.built(try snapshot(rowStatus: "added")).fingerprint

        // then
        #expect(bytes != base && additions != base && bytes != additions)
        #expect(status != original)
    }

    @Test func givenAChangedContentReasonOrState_whenFingerprinted_thenTheFingerprintChanges() throws {
        // given
        func fingerprint(state: String, reason: String?) throws -> Int {
            let row = ChangesJSON.row("f", content: state, reason: reason)
            return try built([ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))]).fingerprint
        }

        // when / then
        let available = try fingerprint(state: "available", reason: nil)
        #expect(try fingerprint(state: "truncated", reason: "file_limit") != available)
        #expect(try fingerprint(state: "truncated", reason: "task_limit") != fingerprint(state: "truncated", reason: "file_limit"))
    }

    @Test func givenAChangedHeadOrScopeCount_whenFingerprinted_thenTheFingerprintChanges() throws {
        // given
        let one = ChangesJSON.repository(committed: ChangesJSON.committed(rows: [ChangesJSON.row("a")]))
        let two = ChangesJSON.repository(committed: ChangesJSON.committed(rowCount: 2, rows: [ChangesJSON.row("a"), ChangesJSON.row("b")]))
        // when / then
        #expect(try built([one]).fingerprint != built([two]).fingerprint)
    }

    @Test func givenNotesAndLoading_whenFingerprinted_thenTheFingerprintIsZero() throws {
        // given / when / then
        #expect(TaskChangesPresentationBuilder.built(try ChangesJSON.pendingRunning()).fingerprint == 0)
        #expect(TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.clientBound(.deadline))).fingerprint == 0)
    }

    private func snapshot(rowStatus: String) throws -> TaskChangesSnapshot {
        let row = ChangesJSON.row("f", status: rowStatus)
        return try ChangesJSON.snapshot(ChangesJSON.page(repositories: [ChangesJSON.repository(committed: ChangesJSON.committed(rows: [row]))]))
    }
}
