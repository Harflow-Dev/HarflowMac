import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskChangesModelTests

struct TaskChangesModelTests {
    private static let repo0: [TCStep] = ["repositories", 0]

    // MARK: Decoding

    @Test func givenSyntheticBaselinePage_whenDecoded_thenEveryFactSurvives() throws {
        // given
        let row = Doc.row(path: "src/a.swift", status: "added", additions: 3, deletions: 0)
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: [row]),
            "working_tree": Doc.working(rows: [], conflicts: [.object(["path": .string("c.txt"), "path_bytes_b64": .null])])
        ])])
        // when
        let decoded = try #require(Doc.decode(page))
        // then
        #expect(decoded.taskID == Doc.taskID && decoded.limit == 200 && !decoded.hasMore && decoded.nextCursor == nil)
        let repository = try #require(decoded.repositories.first)
        #expect(repository.repositoryRoot == Doc.root && repository.worktree == Doc.root && repository.gitCommonDir == Doc.root + "/.git")
        #expect(repository.scopes.map(\.name) == [.committedRange, .workingTree])
        #expect(repository.scope(.committedRange)?.rows.first?.status == .added)
        #expect(repository.scope(.workingTree)?.reportedConflicts?.names.first?.utf8String == "c.txt")
        #expect(repository.scope(.workingTree)?.countsAndPatchSeparate == true)
        #expect(repository.scope(.committedRange)?.unmergedUnknown == nil)
    }

    @Test(arguments: [
        ("repository_root", "repository_root"), ("worktree", "worktree"), ("git_common_dir", "git_common_dir"),
        ("base_commit", "base_commit"), ("base_provenance", "base_provenance"), ("head_commit", "head_commit")
    ])
    func givenSyntheticNullProvenance_whenDecoded_thenItIsKeptAsNilAndMissingKeyIsRejected(key: String, _: String) throws {
        // given
        let nulled = Doc.page().setting(Self.repo0 + [.key(key)], to: .null)
        let missing = Doc.page().setting(Self.repo0 + [.key(key)], to: nil)
        // when / then
        #expect(Doc.decode(nulled) != nil)
        #expect(Doc.decode(missing) == nil)
    }

    @Test func givenSyntheticMissingAttribution_whenDecoded_thenPageIsRejected() {
        // given
        let page = Doc.page().setting(Self.repo0 + ["attribution"], to: nil)
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test(arguments: [
        "Observed repository differences; authored by the task.", "observed repository differences; not evidence of task authorship.",
        "Observed repository differences; not evidence of task authorship. ", ""
    ])
    func givenSyntheticAlteredAttribution_whenDecoded_thenPageIsRejected(statement: String) {
        // given
        let page = Doc.page().setting(Self.repo0 + ["attribution"], to: .string(statement))
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticNonStringAttribution_whenDecoded_thenPageIsRejected() {
        // given
        let page = Doc.page().setting(Self.repo0 + ["attribution"], to: .null)
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test(arguments: [
        ("both", "a.txt", "YS50eHQ="), ("neither", nil, nil), ("encoded-not-string", nil, "not base64!")
    ] as [(String, String?, String?)])
    func givenSyntheticRowPathPair_whenBothOrNeitherOrInvalidBase64_thenRowAndPageAreRejected(_: String, path: String?, encoded: String?) {
        // given
        let row = Doc.row(path: path, pathB64: encoded)
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: [row]),
                                                                   "working_tree": Doc.working()])])
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticRowWithOnlyEncodedPath_whenDecoded_thenExactBytesAreKept() throws {
        // given
        let bytes = Data([0x66, 0xFF, 0xFE, 0x00, 0x2F, 0x67])
        let row = Doc.row(path: nil, pathB64: bytes.base64EncodedString())
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: [row]),
                                                                   "working_tree": Doc.working()])])
        // when
        let decoded = try #require(Doc.decode(page))
        // then
        let path = try #require(decoded.repositories.first?.scope(.committedRange)?.rows.first?.path)
        #expect(path.bytes == bytes && path.utf8String == nil)
        #expect(path.displayString.contains("\u{FFFD}"))
    }

    @Test func givenSyntheticPathOverFourKiB_whenDecoded_thenRowIsRejected() {
        // given
        let long = String(repeating: "p", count: TaskChangesLimits.maxPathBytes + 1)
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: [Doc.row(path: long)]),
                                                                   "working_tree": Doc.working()])])
        // when / then
        #expect(Doc.decode(page) == nil)
        #expect(TaskChangesPath(bytes: Data(repeating: 0x61, count: TaskChangesLimits.maxPathBytes)) != nil)
    }

    @Test(arguments: [
        ["task_id"], ["mode"], ["capture"], ["repositories"], ["limit"], ["has_more"], ["next_cursor"], ["observed_at"]
    ])
    func givenSyntheticMissingTopLevelKey_whenDecoded_thenPageIsRejected(path: [String]) {
        // given
        let page = Doc.page().setting(path.map(TCStep.key), to: nil)
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticTextModeDocument_whenDecodedAsListing_thenItIsRejected() {
        // given
        let page = Doc.page().setting(["mode"], to: .string("text"))
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticHasMoreWithoutCursor_whenDecoded_thenPageIsRejected() {
        // given
        let page = Doc.page().setting(["has_more"], to: .bool(true))
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticCursorWithoutHasMore_whenDecoded_thenPageIsRejected() {
        // given
        let page = Doc.page().setting(["next_cursor"], to: .string("c1"))
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test(arguments: ["", "has\0nul"])
    func givenSyntheticInvalidCursorWithHasMore_whenDecoded_thenPageIsRejected(cursor: String) {
        // given
        let page = Doc.page(cursor: "c1").setting(["next_cursor"], to: .string(cursor))
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticCursorAtAndOverTheBound_whenDecoded_thenOnlyTheBoundIsAccepted() {
        // given
        let atBound = String(repeating: "c", count: TaskChangesLimits.maxCursorCharacters)
        // when / then
        #expect(Doc.decode(Doc.page(cursor: atBound)) != nil)
        #expect(Doc.decode(Doc.page(cursor: atBound + "c")) == nil)
    }

    @Test func givenSyntheticEchoedLimitDiffers_whenDecoded_thenPageIsRejected() {
        // given
        let page = Doc.page(limit: 199)
        // when / then
        #expect(Doc.decode(page, limit: 200) == nil)
        #expect(Doc.decode(page, limit: 199) != nil)
    }

    @Test(arguments: [0, 501, -1])
    func givenSyntheticRequestedLimitOutsideTheContract_whenDecoded_thenPageIsRejected(limit: Int) {
        // given
        let page = Doc.page(limit: limit)
        // when / then
        #expect(Doc.decode(page, limit: limit) == nil)
    }

    @Test func givenSyntheticRowsOverTheLimit_whenDecoded_thenPageIsRejected() {
        // given
        let rows = (0 ..< 3).map { Doc.row(path: "f\($0)") }
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: rows), "working_tree": Doc.working()])],
                           limit: 2)
        // when / then
        #expect(Doc.decode(page, limit: 2) == nil)
        #expect(Doc.decode(page, limit: 3) == nil, "echoed limit still differs")
    }

    @Test func givenSyntheticRowsAcrossScopesEqualToLimit_whenDecoded_thenPageIsAccepted() {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: [Doc.row(path: "a")]), "working_tree": Doc.working(rows: [Doc.row(path: "b")])
        ])], limit: 2)
        // when / then
        #expect(Doc.decode(page, limit: 2) != nil)
    }

    @Test func givenSyntheticNineRepositories_whenDecoded_thenPageIsRejected() {
        // given
        let nine = Doc.page(repositories: (0 ..< 9).map { Doc.repository(root: "/r\($0)") })
        let eight = Doc.page(repositories: (0 ..< 8).map { Doc.repository(root: "/r\($0)") })
        // when / then
        #expect(Doc.decode(nine) == nil)
        #expect(Doc.decode(eight) != nil)
    }

    @Test func givenSyntheticThreeScopes_whenDecoded_thenRepositoryIsRejected() {
        // given
        let scopes: [String: JSONValue] = ["committed_range": Doc.committed(), "working_tree": Doc.working(), "extra": Doc.committed()]
        // when / then
        #expect(Doc.decode(Doc.page(repositories: [Doc.repository(scopes: scopes)])) == nil)
    }

    @Test func givenSyntheticRowCountOverFiveHundred_whenDecoded_thenScopeIsRejected() {
        // given
        let over = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rowCount: 501), "working_tree": Doc.working()])])
        let exact = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rowCount: 500), "working_tree": Doc.working()])])
        // when / then
        #expect(Doc.decode(over) == nil)
        #expect(Doc.decode(exact) != nil)
    }

    @Test func givenSyntheticMoreRowsThanTheRowCount_whenDecoded_thenScopeIsRejected() {
        // given
        let rows = [Doc.row(path: "a"), Doc.row(path: "b")]
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: rows, rowCount: 1),
                                                                   "working_tree": Doc.working()])])
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticWorkingTreeWithoutItsExtraKeys_whenDecoded_thenRepositoryIsRejected() {
        // given
        let base = Doc.page()
        // when / then
        for key in ["counts_and_patch_separate", "unmerged_unknown", "reported_conflicts"] {
            let edited = base.setting(Self.repo0 + ["scopes", "working_tree", .key(key)], to: nil)
            #expect(Doc.decode(edited) == nil, "\(key)")
        }
    }

    @Test func givenSyntheticReportedConflictsOverOneHundred_whenDecoded_thenScopeIsRejected() {
        // given
        let name: JSONValue = .object(["path": .string("c"), "path_bytes_b64": .null])
        let over = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(),
                                                                   "working_tree": Doc.working(conflicts: Array(repeating: name, count: 101))])])
        let exact = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(),
                                                                 "working_tree": Doc.working(conflicts: Array(repeating: name, count: 100))])])
        // when / then
        #expect(Doc.decode(over) == nil)
        #expect(Doc.decode(exact) != nil)
    }

    @Test func givenSyntheticProvenanceOverEscapedBound_whenDecoded_thenRepositoryIsRejected() {
        // given
        let atBound = String(repeating: "x", count: TaskChangesLimits.maxFieldEscapedBytes)
        let quoted = String(repeating: "\"", count: TaskChangesLimits.maxFieldEscapedBytes / 2 + 1)
        // when / then
        #expect(Doc.decode(Doc.page().setting(Self.repo0 + ["worktree"], to: .string(atBound))) != nil)
        #expect(Doc.decode(Doc.page().setting(Self.repo0 + ["worktree"], to: .string(atBound + "x"))) == nil)
        #expect(Doc.decode(Doc.page().setting(Self.repo0 + ["worktree"], to: .string(quoted))) == nil, "escaped form is what counts")
    }

    @Test func givenSyntheticFloatCountToken_whenDecoded_thenRowIsRejected() {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: [Doc.row()]), "working_tree": Doc.working()])])
            .setting(Self.repo0 + ["scopes", "committed_range", "rows", 0, "additions"], to: .number(1, isInteger: false))
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticResolvedFrom_whenValidAndMalformed_thenOnlyAValidOneIsKept() throws {
        // given
        let valid = Doc.page().setting(["resolved_from"], to: .object(["input": .string("task-ch"), "task_id": .string(Doc.taskID)]))
        let malformed = Doc.page().setting(["resolved_from"], to: .object(["input": .string("task-ch")]))
        // when / then
        #expect(try #require(Doc.decode(valid)).resolvedFrom?.input == "task-ch")
        #expect(Doc.decode(malformed) == nil)
    }

    // MARK: Open values

    @Test func givenSyntheticUnknownStatesAndKinds_whenDecoded_thenEveryValueIsKeptVerbatim() throws {
        // given
        let row = Doc.row(path: "f", status: "future_status", content: Doc.content(state: "future_content", reason: "future_reason"))
        let repository = Doc.repository(state: "future_repo_state", reason: "future_repo_reason", dirty: .string("maybe"), scopes: [
            "committed_range": Doc.committed(rows: [row], state: "future_scope_state", reason: "future_scope_reason"),
            "future_scope": Doc.committed()
        ])
        let page = Doc.page(captureState: "future_capture_state", captureReason: "future_capture_reason", repositories: [repository])
            .setting(Self.repo0 + ["base_provenance"], to: .string("future_provenance"))
        // when
        let decoded = try #require(Doc.decode(page))
        // then
        #expect(decoded.capture.state.rawValue == "future_capture_state" && decoded.capture.reason == "future_capture_reason")
        let entry = try #require(decoded.repositories.first)
        #expect(entry.state.rawValue == "future_repo_state" && entry.reason == "future_repo_reason" && entry.baseProvenance == "future_provenance")
        #expect(entry.baselineDirty == .other("maybe"))
        #expect(entry.scopes.map(\.name.rawValue) == ["committed_range", "future_scope"])
        let scope = try #require(entry.scope(.committedRange))
        #expect(scope.state.rawValue == "future_scope_state" && scope.reason == "future_scope_reason")
        let decodedRow = try #require(scope.rows.first)
        #expect(decodedRow.status.rawValue == "future_status")
        #expect(decodedRow.content.state.rawValue == "future_content" && decodedRow.content.reason == "future_reason")
    }

    @Test(arguments: [(JSONValue.bool(true), TaskChangesBaselineDirty.dirty), (.bool(false), .clean), (.string("unknown"), .unknown)])
    func givenSyntheticBaselineDirty_whenDecoded_thenEachSpellingIsDistinct(value: JSONValue, expected: TaskChangesBaselineDirty) throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(dirty: value)])
        // when
        let decoded = try #require(Doc.decode(page))
        // then
        #expect(decoded.repositories.first?.baselineDirty == expected)
    }

    @Test func givenSyntheticNumericBaselineDirty_whenDecoded_thenRepositoryIsRejected() {
        // given
        let page = Doc.page(repositories: [Doc.repository(dirty: .number(1))])
        // when / then
        #expect(Doc.decode(page) == nil)
    }

    @Test func givenSyntheticUnknownScopeAndWorkingTree_whenDecoded_thenKnownScopesComeFirstAndUnknownScopeNeedsNoExtraKeys() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: ["zzz_scope": Doc.committed(), "working_tree": Doc.working()])])
        // when
        let decoded = try #require(Doc.decode(page))
        // then
        #expect(decoded.repositories.first?.scopes.map(\.name.rawValue) == ["working_tree", "zzz_scope"])
    }

    // MARK: Completeness

    @Test func givenSyntheticFullyAvailableCaptureWithZeroRows_whenSnapshotBuilt_thenNoChangesIsEstablished() throws {
        // given / when
        let snapshot = try Doc.snapshot(Doc.page())
        // then
        #expect(snapshot.completeness.isComplete && snapshot.completeness.gaps.isEmpty)
        #expect(snapshot.totalRows == 0 && snapshot.hasNoChanges)
    }

    @Test func givenSyntheticCompleteCaptureWithRows_whenSnapshotBuilt_thenHasNoChangesIsFalse() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: [Doc.row()]), "working_tree": Doc.working()])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.completeness.isComplete && snapshot.totalRows == 1 && !snapshot.hasNoChanges)
    }

    @Test(arguments: [
        ("pending", "task_running"), ("pending", "capture_settling"), ("unavailable", "capture_error"), ("not_captured", "capture_missing"),
        ("incomplete", "capture_timeout"), ("future_state", "future_reason")
    ])
    func givenSyntheticCaptureNotAvailable_whenSnapshotBuilt_thenZeroRowsMeanNothing(state: String, reason: String) throws {
        // given
        let page = Doc.page(captureState: state, captureReason: reason, repositories: [])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.totalRows == 0 && !snapshot.hasNoChanges && !snapshot.completeness.isComplete)
        #expect(snapshot.completeness.gaps == [.captureNotAvailable(state: TaskChangesState(rawValue: state), reason: reason)])
    }

    @Test func givenSyntheticAvailableCaptureWithEveryRepositoryNotCaptured_whenSnapshotBuilt_thenNoChangesIsNotEstablished() throws {
        // given
        let notCaptured = Doc.repository(state: "not_captured", reason: "alternates_present", scopes: [
            "committed_range": Doc.committed(state: "not_captured", reason: "alternates_present"),
            "working_tree": Doc.working(state: "not_captured", reason: "alternates_present")
        ])
        let page = Doc.page(repositories: [notCaptured, Doc.repository(root: "/other", state: "not_captured", reason: "capture_error", scopes: [
            "committed_range": Doc.committed(state: "not_captured"), "working_tree": Doc.working(state: "not_captured")
        ])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.capture.state == .available && snapshot.totalRows == 0)
        #expect(!snapshot.hasNoChanges && !snapshot.completeness.isComplete)
        #expect(snapshot.completeness.gaps.contains(.repositoryNotAvailable(index: 0, state: .notCaptured, reason: "alternates_present")))
        #expect(snapshot.completeness.gaps.contains(.scopeNotAvailable(repositoryIndex: 1, scope: .workingTree, state: .notCaptured, reason: nil)))
    }

    @Test(arguments: ["unavailable", "incomplete", "not_captured"])
    func givenSyntheticScopeNotAvailableInAnAvailableRepository_whenSnapshotBuilt_thenGapNamesTheScope(state: String) throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(), "working_tree": Doc.working(state: state, reason: "git_failed")
        ])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.completeness.gaps == [.scopeNotAvailable(repositoryIndex: 0, scope: .workingTree, state: TaskChangesState(rawValue: state),
                                                                   reason: "git_failed")])
        #expect(!snapshot.hasNoChanges)
    }

    @Test func givenSyntheticTruncatedRowInAnAvailableScope_whenSnapshotBuilt_thenRowContentDoesNotChangeCompleteness() throws {
        // given
        let truncated = Doc.row(path: "big", content: Doc.content(state: "truncated", reason: "file_limit"))
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: [truncated]), "working_tree": Doc.working()])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.completeness.isComplete, "retained-text limits change only a row")
        #expect(!snapshot.hasNoChanges)
    }

    @Test func givenSyntheticRowsTruncatedScope_whenSnapshotBuilt_thenGapIsRowsTruncated() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: [Doc.row()], rowCount: 1, truncated: true), "working_tree": Doc.working()
        ])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.completeness.gaps == [.rowsTruncated(repositoryIndex: 0, scope: .committedRange)])
        #expect(!snapshot.completeness.isComplete && !snapshot.hasNoChanges)
    }

    @Test func givenSyntheticRowsTruncatedWithZeroRows_whenSnapshotBuilt_thenNoChangesIsNotEstablished() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(truncated: true), "working_tree": Doc.working()
        ])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(!snapshot.hasNoChanges)
    }

    @Test func givenSyntheticUnmergedUnknown_whenSnapshotBuilt_thenGapIsUnmergedUnknownAndNoChangesNotEstablished() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(), "working_tree": Doc.working(unmergedUnknown: true)])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.completeness.gaps == [.unmergedUnknown(repositoryIndex: 0)])
        #expect(!snapshot.hasNoChanges)
    }

    @Test func givenSyntheticRepositoryMissingAKnownScope_whenSnapshotBuilt_thenGapIsScopeMissing() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed()])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.completeness.gaps == [.scopeMissing(repositoryIndex: 0, scope: .workingTree)])
        #expect(!snapshot.hasNoChanges)
    }

    @Test func givenSyntheticTwoGapsInDifferentRepositories_whenSnapshotBuilt_thenGapsAreIndexedByRepository() throws {
        // given
        let page = Doc.page(repositories: [
            Doc.repository(root: "/ok"),
            Doc.repository(root: "/bad", state: "unavailable", reason: "repository_unavailable", scopes: [
                "committed_range": Doc.committed(state: "unavailable"), "working_tree": Doc.working(unmergedUnknown: true)
            ])
        ])
        // when
        let gaps = try Doc.snapshot(page).completeness.gaps
        // then
        #expect(gaps.contains(.repositoryNotAvailable(index: 1, state: .unavailable, reason: "repository_unavailable")))
        #expect(gaps.contains(.unmergedUnknown(repositoryIndex: 1)))
        #expect(!gaps.contains { if case .repositoryNotAvailable(0, _, _) = $0 { true } else { false } })
    }

    // MARK: No changes

    @Test func givenSyntheticAvailableCaptureWithNullReasonAndNoRepositories_whenSnapshotBuilt_thenNoChangesIsNotEstablished() throws {
        // given / when
        let snapshot = try Doc.snapshot(Doc.page(repositories: []))
        // then
        #expect(snapshot.completeness.isComplete && snapshot.capture.reason == nil && snapshot.totalRows == 0)
        #expect(!snapshot.hasNoChanges)
    }

    @Test func givenSyntheticCompleteRepositoryWithACaptureReason_whenSnapshotBuilt_thenNoChangesIsNotEstablished() throws {
        // given / when
        let snapshot = try Doc.snapshot(Doc.page(captureReason: "no_repository"))
        // then
        #expect(snapshot.completeness.isComplete && snapshot.totalRows == 0 && !snapshot.hasNoChanges)
    }

    @Test(arguments: ["names", "truncated-names"])
    func givenSyntheticReportedConflictsWithZeroRows_whenSnapshotBuilt_thenNoChangesIsNotEstablished(mode: String) throws {
        // given
        let name: JSONValue = .object(["path": .string("c.txt"), "path_bytes_b64": .null])
        var working = Doc.working(conflicts: mode == "names" ? [name] : []).asObject
        if mode == "truncated-names" { working["reported_conflicts"] = .object(["names": .array([]), "truncated": .bool(true)]) }
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(), "working_tree": .object(working)])])
        // when
        let snapshot = try Doc.snapshot(page)
        // then
        #expect(snapshot.completeness.isComplete && snapshot.totalRows == 0)
        #expect(!snapshot.hasNoChanges)
    }

    @Test func givenSyntheticReportedConflictsAtAndOverTheEscapedBound_whenDecoded_thenOnlyTheBoundIsAccepted() {
        // given: each name prints as len + 38 bytes (37 for a one-byte name, plus 2 for the separator, less the byte), so eight names of 986 bytes fill 8192 exactly
        func page(lastLength: Int) -> JSONValue {
            let names = (0 ..< 8).map { index -> JSONValue in
                .object(["path": .string(String(repeating: "n", count: index == 7 ? lastLength : 986)), "path_bytes_b64": .null])
            }
            return Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(), "working_tree": Doc.working(conflicts: names)])])
        }
        // when / then
        #expect(TaskChangesLimits.maxReportedConflictsEscapedBytes == 8192)
        #expect(Doc.decode(page(lastLength: 986)) != nil)
        #expect(Doc.decode(page(lastLength: 987)) == nil)
    }

    // MARK: Selector

    @Test func givenSyntheticFullyIdentifiedRow_whenSelectorMade_thenItCarriesRootScopeAndExactBytes() throws {
        // given
        let bytes = Data([0x61, 0xFF, 0x2F, 0x62])
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: [Doc.row(path: nil, pathB64: bytes.base64EncodedString())]), "working_tree": Doc.working()
        ])])
        let repository = try #require(Doc.decode(page)?.repositories.first)
        let row = try #require(repository.scope(.committedRange)?.rows.first)
        // when
        let selector = try #require(TaskChangesSelector(repository: repository, scope: .committedRange, row: row))
        // then
        #expect(selector.repositoryRoot == Doc.root && selector.scope == .committedRange && selector.pathBytes == bytes)
    }

    @Test(arguments: [
        ("binary", Doc.row(path: "i.bin", binary: true, content: Doc.content(state: "binary"))),
        ("not-captured", Doc.row(path: "n", content: Doc.content(state: "not_captured", reason: "patch_failed"))),
        ("omitted-size", Doc.row(path: "o", content: Doc.content(state: "omitted_size", reason: "task_limit"))),
        ("untracked", Doc.row(path: "u", status: "untracked", content: Doc.content(state: "not_captured", reason: "untracked"))),
        ("future-content", Doc.row(path: "f", content: Doc.content(state: "future_content")))
    ] as [(String, JSONValue)])
    func givenSyntheticRowWhoseContentIsNotAvailable_whenSelectorMade_thenItStaysAddressable(_: String, row: JSONValue) throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: [row]), "working_tree": Doc.working()])])
        let repository = try #require(Doc.decode(page)?.repositories.first)
        let decoded = try #require(repository.scope(.committedRange)?.rows.first)
        // when / then
        #expect(TaskChangesSelector(repository: repository, scope: .committedRange, row: decoded) != nil)
    }

    @Test func givenSyntheticRowWithTruncatedPath_whenSelectorMade_thenItIsNil() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: [Doc.row(path: "cut", pathTruncated: true)]), "working_tree": Doc.working()
        ])])
        let repository = try #require(Doc.decode(page)?.repositories.first)
        let row = try #require(repository.scope(.committedRange)?.rows.first)
        // when / then
        #expect(TaskChangesSelector(repository: repository, scope: .committedRange, row: row) == nil)
    }

    @Test func givenSyntheticRepositoryWithTruncatedFields_whenSelectorMade_thenItIsNil() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(fieldsTruncated: true, scopes: [
            "committed_range": Doc.committed(rows: [Doc.row()]), "working_tree": Doc.working()
        ])])
        let repository = try #require(Doc.decode(page)?.repositories.first)
        let row = try #require(repository.scope(.committedRange)?.rows.first)
        // when / then
        #expect(TaskChangesSelector(repository: repository, scope: .committedRange, row: row) == nil)
    }

    @Test func givenSyntheticRepositoryWithoutRoot_whenSelectorMade_thenItIsNil() throws {
        // given
        let page = Doc.page(repositories: [Doc.repository(root: nil, scopes: [
            "committed_range": Doc.committed(rows: [Doc.row()]), "working_tree": Doc.working()
        ])])
        let repository = try #require(Doc.decode(page)?.repositories.first)
        let row = try #require(repository.scope(.committedRange)?.rows.first)
        // when / then
        #expect(repository.repositoryRoot == nil)
        #expect(TaskChangesSelector(repository: repository, scope: .committedRange, row: row) == nil)
    }

    @Test func givenSyntheticRowWithEmptyPath_whenSelectorMade_thenItIsNil() throws {
        // given
        let scopes = ["committed_range": Doc.committed(rows: [Doc.row(path: "")]), "working_tree": Doc.working()]
        let page = Doc.page(repositories: [Doc.repository(scopes: scopes)])
        let repository = try #require(Doc.decode(page)?.repositories.first)
        let row = try #require(repository.scope(.committedRange)?.rows.first)
        // when / then
        #expect(row.path.bytes.isEmpty)
        #expect(TaskChangesSelector(repository: repository, scope: .committedRange, row: row) == nil)
    }

    @Test(arguments: [("", "committed_range", 1), ("/r", "", 1), ("/r", "working_tree", 0), ("/r", "working_tree", 4097), ("/r\0x", "working_tree", 1),
                      ("/r", "working\0tree", 1)])
    func givenSyntheticSelectorParts_whenInvalid_thenInitFails(root: String, scope: String, length: Int) {
        // given / when
        let selector = TaskChangesSelector(repositoryRoot: root, scope: TaskChangesScopeName(rawValue: scope), pathBytes: Data(repeating: 0x61, count: length))
        // then
        #expect(selector == nil)
    }

    @Test func givenSyntheticSelectorAtThePathBound_whenMade_thenItIsAccepted() {
        // given / when
        let selector = TaskChangesSelector(repositoryRoot: "/r", scope: .workingTree, pathBytes: Data(repeating: 0x61, count: 4096))
        // then
        #expect(selector != nil)
    }
}
