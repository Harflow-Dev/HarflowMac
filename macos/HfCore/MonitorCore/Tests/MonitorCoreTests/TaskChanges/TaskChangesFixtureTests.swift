import Foundation
@testable import MonitorCore
import Testing

// MARK: - Fixture catalogue

/// Every `ctl-task-changes-*` fixture with the exit code the engine prints it under. The manifest
/// records no `exit_code` for these, so a result is read as 0 and a refusal as 1 (contract: refusals
/// carry exit 1). A fixture listed here without a case in `TaskChangesFixtureTests.assertFact` fails.
enum TCFixtureCatalogue {
    static let results: [String] = [
        "available-listing", "listing-next-page", "incomplete", "no-repository", "not-captured-missing", "not-captured-unobserved",
        "pending-running", "pending-settling", "unavailable", "document-invalid", "text-chunk", "text-chunk-next", "text-complete"
    ]
    static let refusals: [String: String] = [
        "cursor-expired": "changes_cursor_expired", "cursor-invalid": "changes_cursor_invalid",
        "direct-caller-refused": "caller_undecidable", "entry-not-found": "changes_entry_not_found",
        "page-too-large": "changes_page_too_large", "pending-launch": "task_pending_launch", "unknown-task": "unknown_task"
    ]

    static var stems: [String] { results + refusals.keys.sorted() }
    static var files: Set<String> { Set(stems.map(TCFixture.file)) }
    static func exit(_ stem: String) -> Int32 { refusals[stem] == nil ? 0 : 1 }
}

// MARK: - TaskChangesFixtureTests

struct TaskChangesFixtureTests {
    @Test func givenVendoredTaskChangesFixtures_whenCatalogued_thenAllTwentyAreAssertedAndNoneIsMissing() throws {
        // given
        let asserted = TCFixtureCatalogue.files
        // when
        let listed = try TCFixture.manifestNames()
        let bundled = TCFixture.bundledNames()
        // then
        #expect(asserted.count == 20)
        #expect(listed.subtracting(asserted).isEmpty, "manifest fixtures without an assertion: \(listed.subtracting(asserted).sorted())")
        #expect(bundled.subtracting(asserted).isEmpty, "bundled fixtures without an assertion: \(bundled.subtracting(asserted).sorted())")
        #expect(asserted.subtracting(listed).isEmpty, "asserted but not in manifest: \(asserted.subtracting(listed).sorted())")
        #expect(asserted.subtracting(bundled).isEmpty, "asserted but not bundled: \(asserted.subtracting(bundled).sorted())")
    }

    @Test(arguments: TCFixtureCatalogue.stems)
    func givenFixture_whenManifestRead_thenItIsValidForTheCurrentVersionAndNamesTheCapability(stem: String) throws {
        // given / when
        let entry = try TCFixture.manifestCase(stem)
        // then
        #expect(entry["valid"]?.boolValue == true)
        #expect(entry["format"]?.stringValue == "harflow.ctl")
        #expect(entry["expected_product_version"]?.stringValue == HarflowVersion.current)
        #expect(entry["required_capabilities"]?.arrayValue?.compactMap(\.stringValue) == [CtlCapability.taskChanges])
    }

    @Test(arguments: TCFixtureCatalogue.stems)
    func givenFixture_whenShapeRead_thenResultsAndRefusalsMatchTheCatalogueExit(stem: String) throws {
        // given
        let document = try TCFixture.document(stem)
        // when
        let isRefusal = document["error"] != nil
        // then
        #expect(isRefusal == (TCFixtureCatalogue.exit(stem) == 1))
        #expect(isRefusal != (document["result"] != nil))
    }

    @Test(arguments: TCFixtureCatalogue.stems)
    func givenFixture_whenReadThroughTheClient_thenTheDistinguishingFactHolds(stem: String) async throws {
        // given
        let output = TCFixture.output(stem, exit: TCFixtureCatalogue.exit(stem))
        let runner = changesRunner { _ in output }
        let client = changesClient(runner)
        // when / then
        try await Self.assertFact(stem, client: client, runner: runner)
    }

    // MARK: Per-fixture assertions

    // swiftlint:disable:next function_body_length
    static func assertFact(_ stem: String, client: CtlClient, runner: RecordingRunner) async throws {
        let result = try TCFixture.document(stem)["result"]?.objectValue
        let taskID = result?["task_id"]?.stringValue ?? "task"
        let limit = result?["limit"]?.wireIntegerValue ?? 200
        switch stem {
        case "available-listing":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(limit == 2)
            #expect(page.capture.state == .available && page.capture.reason == nil)
            #expect(page.hasMore && page.nextCursor != nil)
            let repository = try #require(page.repositories.first)
            #expect(repository.baselineDirty == .clean && repository.baseProvenance == "dispatch" && !repository.fieldsTruncated)
            let committed = try #require(repository.scope(.committedRange))
            #expect(committed.rowCount == 4 && committed.rows.map(\.path.utf8String) == ["README.md", "docs/guide.md"])
            let working = try #require(repository.scope(.workingTree))
            #expect(working.rowCount == 2 && working.rows.isEmpty && working.unmergedUnknown == false)
            var builder = TaskChangesListingBuilder()
            try builder.append(page)
            #expect(!builder.isFinished)
            #expect(throws: TaskChangesAssemblyError.unfinished) { try builder.finish() }
        case "listing-next-page":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(!page.hasMore && page.nextCursor == nil)
            let repository = try #require(page.repositories.first)
            let committed = try #require(repository.scope(.committedRange))
            let binary = try #require(committed.rows.last)
            #expect(binary.binary && binary.additions == nil && binary.deletions == nil && binary.content.state == .binary)
            let untracked = try #require(repository.scope(.workingTree)?.rows.last)
            #expect(untracked.status == .untracked && untracked.content.state == .notCaptured && untracked.content.reason == "untracked")
            #expect(TaskChangesSelector(repository: repository, scope: .committedRange, row: binary) != nil)
            #expect(TaskChangesSelector(repository: repository, scope: .workingTree, row: untracked) != nil)
        case "incomplete":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(page.capture.state == .incomplete && page.capture.reason == "capture_timeout")
            let repository = try #require(page.repositories.first)
            #expect(repository.state == .incomplete)
            #expect(repository.scope(.committedRange)?.state == .incomplete)
            #expect(repository.scope(.committedRange)?.rows.first?.content.state == .truncated)
            let snapshot = try Doc.snapshot(.object(result ?? [:]))
            #expect(!snapshot.completeness.isComplete && !snapshot.hasNoChanges)
        case "no-repository":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(page.capture.state == .available && page.capture.reason == "no_repository")
            #expect(page.repositories.isEmpty)
            let snapshot = try Doc.snapshot(.object(result ?? [:]))
            #expect(snapshot.completeness.isComplete && snapshot.totalRows == 0)
            #expect(!snapshot.hasNoChanges, "no repository was observed, so nothing is established")
        case "not-captured-missing", "not-captured-unobserved":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(page.capture.state == .notCaptured)
            #expect(page.capture.reason == (stem == "not-captured-missing" ? "capture_missing" : "outcome_unobserved"))
            #expect(page.repositories.isEmpty)
            let snapshot = try Doc.snapshot(.object(result ?? [:]))
            #expect(!snapshot.completeness.isComplete && !snapshot.hasNoChanges)
        case "pending-running":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(page.capture.state == .pending && page.repositories.isEmpty)
            #expect(page.capture.reason == "task_running")
            let snapshot = try Doc.snapshot(.object(result ?? [:]))
            #expect(!snapshot.completeness.isComplete && !snapshot.hasNoChanges)
        case "pending-settling":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(page.capture.reason == "capture_settling")
            let snapshot = try Doc.snapshot(.object(result ?? [:]))
            #expect(!snapshot.hasNoChanges)
        case "unavailable", "document-invalid":
            let page = try await client.taskChangesPage(taskID: taskID, limit: limit).get()
            #expect(page.capture.state == .unavailable)
            #expect(page.capture.reason == (stem == "unavailable" ? "capture_error" : "changes_document_invalid"))
            let snapshot = try Doc.snapshot(.object(result ?? [:]))
            #expect(!snapshot.completeness.isComplete && !snapshot.hasNoChanges)
        case "text-chunk":
            let chunk = try await client.taskChangesTextChunk(taskID: taskID, selector: Doc.selector(
                root: "/workspace/repo", scope: .committedRange, path: "docs/guide.md"))
.get()
            #expect(chunk.offset == 0 && chunk.bytes.count == 330 && chunk.totalBytes == 1323)
            #expect(chunk.hasMore && chunk.nextCursor != nil && chunk.encoding == .utf8)
            #expect(chunk.scope == .committedRange && chunk.status == .added)
        case "text-chunk-next":
            let chunk = try await client.taskChangesTextChunk(taskID: taskID, cursor: "cursor").get()
            #expect(chunk.offset == 330 && chunk.bytes.count == 248 && chunk.totalBytes == 1323 && chunk.hasMore)
            let first = try #require(TaskChangesTextChunk(raw: TCFixture.result("text-chunk")))
            #expect(first.offset + first.bytes.count == chunk.offset)
            var assembler = TaskChangesTextAssembler(selector: try Doc.selector(root: "/workspace/repo", scope: .committedRange, path: "docs/guide.md"))
            try assembler.append(first)
            try assembler.append(chunk)
            #expect(assembler.nextCursor == chunk.nextCursor)
            #expect(throws: TaskChangesAssemblyError.unfinished) { try assembler.finish() }
        case "text-complete":
            let chunk = try await client.taskChangesTextChunk(taskID: taskID, cursor: "cursor").get()
            #expect(!chunk.hasMore && chunk.nextCursor == nil && chunk.offset == 0 && chunk.bytes.count == chunk.totalBytes)
            var assembler = TaskChangesTextAssembler(selector: try Doc.selector(root: "/workspace/repo", scope: .committedRange, path: "src/app.py"))
            try assembler.append(chunk)
            let patch = try assembler.finish()
            #expect(patch.bytes == chunk.bytes && patch.utf8String?.hasPrefix("diff --git a/src/app.py") == true)
        case "cursor-expired":
            let error = try await Self.refusal(client.taskChangesPage(taskID: "task"))
            #expect(error.refusalCode == TaskChangesRefusalCode.cursorExpired && error.isTaskChangesCursorExpired)
            #expect(error.refusalData?["reload"]?.stringValue == "first")
        case "cursor-invalid", "entry-not-found", "page-too-large", "direct-caller-refused":
            let error = try await Self.refusal(client.taskChangesPage(taskID: "task"))
            #expect(error.refusalCode == TCFixtureCatalogue.refusals[stem])
            #expect(!error.isTaskChangesCursorExpired)
        case "pending-launch":
            let error = try await Self.refusal(client.taskChangesPage(taskID: "task"))
            #expect(error.refusalCode == TaskChangesRefusalCode.taskPendingLaunch)
            #expect(error.refusalData?["launch_state"]?.stringValue == "waiting_for_resources")
        case "unknown-task":
            let error = try await Self.refusal(client.taskChangesPage(taskID: "task"))
            #expect(error.refusalCode == "unknown_task")
            #expect(error.refusalData?["reason"]?.stringValue == "no_prefix_match")
        default:
            Issue.record("fixture \(stem) has no assertion")
        }
        #expect(runner.calls.count == 1)
    }

    private static func refusal(_ result: Result<some Any, ToolError>) throws -> ToolError {
        guard case .failure(let error) = result else {
            Issue.record("refusal fixture decoded as a result")
            throw ToolError.unreadable(tool: "fixture", exitCode: 0, stderr: "accepted")
        }
        return error
    }
}
