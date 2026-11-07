import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskChangesListingBuilderTests

struct TaskChangesListingBuilderTests {
    /// One repository whose committed scope stores `total` rows, `rows` of them on this page.
    private static func page(rows: [String], total: Int, cursor: String?, task: String = Doc.taskID, limit: Int = 200,
                             repositoryEdit: ((inout [String: JSONValue]) -> Void)? = nil,
                             captureReason: String? = nil) -> JSONValue {
        var repository = Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: rows.map { Doc.row(path: $0) }, rowCount: total), "working_tree": Doc.working()
        ])
.asObject
        repositoryEdit?(&repository)
        return Doc.page(task: task, captureReason: captureReason, repositories: [.object(repository)], limit: limit, cursor: cursor)
    }

    private static func decoded(_ page: JSONValue, limit: Int = 200) throws -> TaskChangesPage {
        try #require(Doc.decode(page, limit: limit))
    }

    // MARK: Happy path

    @Test func givenSyntheticTwoPagesOfOneDocument_whenAppended_thenRowsAreMergedPerScopeInOrder() throws {
        // given
        var builder = TaskChangesListingBuilder()
        // when
        try builder.append(Self.decoded(Self.page(rows: ["a", "b"], total: 3, cursor: "c1")))
        let midway = (builder.isFinished, builder.nextCursor)
        try builder.append(Self.decoded(Self.page(rows: ["c"], total: 3, cursor: nil)))
        let snapshot = try builder.finish()
        // then
        #expect(midway.0 == false && midway.1 == "c1")
        #expect(builder.isFinished && builder.nextCursor == nil)
        let scope = try #require(snapshot.repositories.first?.scope(.committedRange))
        #expect(scope.rows.compactMap(\.path.utf8String) == ["a", "b", "c"])
        #expect(snapshot.pagesRead == 2 && snapshot.totalRows == 3 && snapshot.taskID == Doc.taskID)
        #expect(snapshot.completeness.isComplete)
    }

    @Test func givenVendoredFixturePages_whenAppendedUnmodified_thenTheTwoPageDocumentMergesToItsRowCounts() throws {
        // given: the engine recorded page 1 at limit 2 and page 2 at the default 200
        var builder = TaskChangesListingBuilder()
        // when
        try builder.append(TCFixture.page("available-listing", limit: 2))
        try builder.append(TCFixture.page("listing-next-page", limit: 200))
        let snapshot = try builder.finish()
        // then
        let repository = try #require(snapshot.repositories.first)
        #expect(repository.scope(.committedRange)?.rows.compactMap(\.path.utf8String) == ["README.md", "docs/guide.md", "src/app.py", "assets/logo.png"])
        #expect(repository.scope(.workingTree)?.rows.compactMap(\.path.utf8String) == ["src/app.py", "notes.txt"])
        #expect(snapshot.totalRows == 6 && snapshot.pagesRead == 2 && snapshot.completeness.isComplete)
    }

    @Test func givenSyntheticSinglePageWithNoMore_whenFinished_thenSnapshotIsBuiltFromIt() throws {
        // given
        var builder = TaskChangesListingBuilder()
        // when
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 1, cursor: nil)))
        // then
        #expect(try builder.finish().pagesRead == 1)
    }

    @Test func givenSyntheticTwoPages_whenFinished_thenObservedAtIsTheFinalPages() throws {
        // given
        var builder = TaskChangesListingBuilder()
        let last = Self.page(rows: ["b"], total: 2, cursor: nil).setting(["observed_at"], to: .string("2026-10-14T17:50:00+00:00"))
        // when
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 2, cursor: "c1")))
        try builder.append(Self.decoded(last))
        // then
        #expect(try builder.finish().observedAt == "2026-10-14T17:50:00+00:00")
    }

    // MARK: Fail closed

    @Test func givenSyntheticBuilderWithNoPage_whenFinished_thenItIsUnfinished() {
        // given
        let builder = TaskChangesListingBuilder()
        // when / then
        #expect(!builder.isFinished && builder.nextCursor == nil)
        #expect(throws: TaskChangesAssemblyError.unfinished) { try builder.finish() }
    }

    @Test func givenSyntheticBuilderAfterAPageWithMore_whenFinished_thenItIsUnfinished() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 2, cursor: "c1")))
        // when / then
        #expect(throws: TaskChangesAssemblyError.unfinished) { try builder.finish() }
    }

    @Test func givenSyntheticRepeatedCursor_whenAppended_thenItIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 3, cursor: "same")))
        // when / then
        #expect(throws: TaskChangesAssemblyError.repeatedCursor) {
            try builder.append(Self.decoded(Self.page(rows: ["b"], total: 3, cursor: "same")))
        }
    }

    @Test func givenSyntheticPageWithMoreButNoRows_whenAppended_thenNoProgressIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        // when / then
        #expect(throws: TaskChangesAssemblyError.noProgress) {
            try builder.append(Self.decoded(Self.page(rows: [], total: 1, cursor: "c1")))
        }
    }

    @Test func givenSyntheticEmptyFinalPage_whenAppended_thenItIsAcceptedBecauseProgressIsOnlyRequiredWhileMoreRemain() throws {
        // given
        var builder = TaskChangesListingBuilder()
        // when
        try builder.append(Self.decoded(Self.page(rows: [], total: 0, cursor: nil)))
        // then
        #expect(try builder.finish().totalRows == 0)
    }

    @Test func givenSyntheticSecondPageForAnotherTask_whenAppended_thenTaskChangedIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 2, cursor: "c1")))
        // when / then
        #expect(throws: TaskChangesAssemblyError.taskChanged) {
            try builder.append(Self.decoded(Self.page(rows: ["b"], total: 2, cursor: nil, task: "other")))
        }
    }

    // MARK: Finished, duplicates

    @Test func givenSyntheticFinishedBuilder_whenAnotherPageIsAppended_thenAlreadyFinishedIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 2, cursor: nil)))
        // when / then
        #expect(throws: TaskChangesAssemblyError.alreadyFinished) {
            try builder.append(Self.decoded(Self.page(rows: ["b"], total: 2, cursor: nil)))
        }
        #expect(builder.isFinished)
    }

    @Test func givenSyntheticRepeatedPathWithinOnePage_whenRowCountIsTwo_thenDuplicateRowIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        let page = try Self.decoded(Self.page(rows: ["same", "same"], total: 2, cursor: nil))
        // when / then
        #expect(throws: TaskChangesAssemblyError.duplicateRow) { try builder.append(page) }
    }

    @Test func givenSyntheticRepeatedPathAcrossPages_whenRowCountIsTwo_thenDuplicateRowIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["same"], total: 2, cursor: "c1")))
        // when / then
        #expect(throws: TaskChangesAssemblyError.duplicateRow) {
            try builder.append(Self.decoded(Self.page(rows: ["same"], total: 2, cursor: nil)))
        }
    }

    @Test func givenSyntheticSamePathInDifferentScopes_whenAppended_thenBothRowsAreKept() throws {
        // given
        var builder = TaskChangesListingBuilder()
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: [Doc.row(path: "same")]), "working_tree": Doc.working(rows: [Doc.row(path: "same")])
        ])])
        // when
        try builder.append(Self.decoded(page))
        // then
        #expect(try builder.finish().totalRows == 2)
    }

    @Test func givenSyntheticRepeatedTruncatedPaths_whenAppended_thenTheyAreNotDuplicates() throws {
        // given
        var builder = TaskChangesListingBuilder()
        let rows = [Doc.row(path: "cut", pathTruncated: true), Doc.row(path: "cut", pathTruncated: true)]
        let page = Doc.page(repositories: [Doc.repository(scopes: ["committed_range": Doc.committed(rows: rows), "working_tree": Doc.working()])])
        // when
        try builder.append(Self.decoded(page))
        // then
        #expect(try builder.finish().totalRows == 2)
    }

    @Test func givenSyntheticSamePathInTwoRepositories_whenAppended_thenBothRowsAreKept() throws {
        // given
        var builder = TaskChangesListingBuilder()
        func repository(_ root: String) -> JSONValue {
            Doc.repository(root: root, scopes: ["committed_range": Doc.committed(rows: [Doc.row(path: "same")]), "working_tree": Doc.working()])
        }
        // when
        try builder.append(Self.decoded(Doc.page(repositories: [repository("/a"), repository("/b")])))
        // then
        #expect(try builder.finish().totalRows == 2)
    }

    @Test(arguments: ["capture-state", "capture-reason", "head", "scope-row-count", "scope-state", "repository-state", "repository-added", "root"])
    func givenSyntheticSecondPageWhoseSkeletonDiffers_whenAppended_thenDocumentChangedIsRefused(change: String) throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 3, cursor: "c1")))
        var second = Self.page(rows: ["b"], total: 3, cursor: nil)
        let repository: [TCStep] = ["repositories", 0]
        switch change {
        case "capture-state": second = second.setting(["capture", "state"], to: .string("incomplete"))
        case "capture-reason": second = second.setting(["capture", "reason"], to: .string("capture_timeout"))
        case "head": second = second.setting(repository + ["head_commit"], to: .string(String(repeating: "c", count: 40)))
        case "scope-row-count": second = second.setting(repository + ["scopes", "committed_range", "row_count"], to: .number(4))
        case "scope-state": second = second.setting(repository + ["scopes", "committed_range", "state"], to: .string("incomplete"))
        case "repository-state": second = second.setting(repository + ["state"], to: .string("incomplete"))
        case "root": second = second.setting(repository + ["repository_root"], to: .string("/elsewhere"))
        default:
            second = second.setting(["repositories"], to: .array([second.asObject["repositories"]?.arrayValue?.first ?? .null, Doc.repository(root: "/extra")]))
        }
        // when / then
        #expect(throws: TaskChangesAssemblyError.documentChanged) { try builder.append(Self.decoded(second)) }
    }

    @Test func givenSyntheticSecondPageWithTheSameSkeleton_whenAppended_thenOnlyRowsMayDiffer() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 2, cursor: "c1")))
        // when / then
        try builder.append(Self.decoded(Self.page(rows: ["b"], total: 2, cursor: nil)))
        #expect(try builder.finish().totalRows == 2)
    }

    @Test func givenSyntheticMergedRowsFewerThanRowCount_whenFinished_thenRowCountMismatchIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a"], total: 2, cursor: "c1")))
        try builder.append(Self.decoded(Self.page(rows: [], total: 2, cursor: nil)))
        // when / then
        #expect(throws: TaskChangesAssemblyError.rowCountMismatch) { try builder.finish() }
    }

    @Test func givenSyntheticMergedRowsMoreThanRowCount_whenAppended_thenRowCountMismatchIsRefused() throws {
        // given
        var builder = TaskChangesListingBuilder()
        try builder.append(Self.decoded(Self.page(rows: ["a", "b"], total: 3, cursor: "c1")))
        // when / then
        #expect(throws: TaskChangesAssemblyError.rowCountMismatch) {
            try builder.append(Self.decoded(Self.page(rows: ["c", "d"], total: 3, cursor: nil)))
        }
    }

    @Test func givenSyntheticRowsThatAreTruncatedInTheScope_whenAllPagesRead_thenStoredRowsStillMatchRowCount() throws {
        // given: rows_truncated means more existed than stored; row_count counts stored rows
        var builder = TaskChangesListingBuilder()
        let page = Doc.page(repositories: [Doc.repository(scopes: [
            "committed_range": Doc.committed(rows: [Doc.row(path: "a")], rowCount: 1, truncated: true), "working_tree": Doc.working()
        ])])
        // when
        try builder.append(Self.decoded(page))
        let snapshot = try builder.finish()
        // then
        #expect(snapshot.completeness.gaps == [.rowsTruncated(repositoryIndex: 0, scope: .committedRange)])
    }

    @Test func givenSyntheticSixteenFullScopes_whenAnotherRowArrives_thenRowLimitExceededIsRefused() throws {
        // given: 8 repositories x 2 scopes x 500 rows fill the ceiling, one scope per page
        var builder = TaskChangesListingBuilder()
        func page(filling slot: Int?, cursor: String?) -> JSONValue {
            let repositories = (0 ..< 8).map { index -> JSONValue in
                func rows(_ scope: Int) -> [JSONValue] {
                    guard slot == index * 2 + scope else { return [] }
                    return (0 ..< 500).map { Doc.row(path: "f\($0)") }
                }
                return Doc.repository(root: "/r\(index)", scopes: [
                    "committed_range": Doc.committed(rows: rows(0), rowCount: 500), "working_tree": Doc.working(rows: rows(1), rowCount: 500)
                ])
            }
            return Doc.page(repositories: repositories, limit: 500, cursor: cursor)
        }
        // when
        for slot in 0 ..< 16 { try builder.append(Self.decoded(page(filling: slot, cursor: "c\(slot)"), limit: 500)) }
        // then
        #expect(TaskChangesLimits.maxRows == 8000)
        #expect(throws: TaskChangesAssemblyError.rowLimitExceeded) {
            try builder.append(Self.decoded(page(filling: 0, cursor: nil), limit: 500))
        }
    }
}
