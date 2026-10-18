import Foundation
@testable import MonitorCore
import Testing

// MARK: - StatusBatchTests

/// `polybridge-ctl status-batch --json` decoding: `tasks` and per-id `errors` kept together by a
/// dedicated decoder, driven from real JSON — never a mocked client.
@Suite struct StatusBatchTests {

    private func ok(_ text: String) -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: Data(text.utf8), stderr: "", timedOut: false)
    }

    @Test func givenAMixedBatch_whenDecoded_thenTasksAndErrorsAreBothKept() throws {
        // given — a document the generic `tasks` branch would have stripped down to just the array.
        let stdout = json(#"""
        {"v":11,"tasks":[
            {"task_id":"a","status":"running","backend":"claude","started_at":"2026-10-17T10:00:00+00:00"},
            {"task_id":"b","status":"completed","backend":"codex"}
        ],"errors":{
            "c":{"code":"unknown_task","message":"task c is not on disk"},
            "d":{"code":"agent_caller","message":"refused"}
        }}
        """#)

        // when
        let result = CtlDocument.decodeBatchResult(stdout: stdout, stderr: "", exitCode: 0, command: "status-batch")

        // then
        let batch = try #require(try result.get())
        #expect(batch.tasks.map(\.taskID) == ["a", "b"])
        #expect(batch.errors["c"]?.code == "unknown_task")
        #expect(batch.errors["d"]?.message == "refused")
        #expect(batch.errors["e"] == nil)
    }

    @Test func givenABatchWithNoErrorsKey_whenDecoded_thenTheTasksDecode() throws {
        // given
        let stdout = json(#"{"v":11,"tasks":[{"task_id":"a","status":"running","backend":"claude"}]}"#)
        // when
        let batch = try #require(try CtlDocument.decodeBatchResult(stdout: stdout, stderr: "", exitCode: 0, command: "status-batch").get())
        // then
        #expect(batch.tasks.map(\.taskID) == ["a"])
        #expect(batch.errors.isEmpty)
    }

    @Test func givenABatchErrorDocument_whenDecoded_thenTheWholeBatchFails() {
        // given — authority failures fail the whole command, never partial data.
        let stdout = json(#"{"v":11,"error":{"code":"caller_undecidable","message":"could not decide"}}"#)
        // when
        let result = CtlDocument.decodeBatchResult(stdout: stdout, stderr: "", exitCode: 0, command: "status-batch")
        // then
        #expect(result == .failure(.refused(code: "caller_undecidable", message: "could not decide")))
    }

    @Test func givenAnOlderCtlWithoutTheCommand_whenDecoded_thenItIsUnsupportedCommand() {
        // given — argparse exit 2, prose stderr, the same shape `backends` relies on.
        let result = CtlDocument.decodeBatchResult(stdout: Data(), stderr: "invalid choice: 'status-batch'", exitCode: 2, command: "status-batch")
        // when / then
        guard case .failure(.unsupportedCommand(let tool, let command, _)) = result else {
            Issue.record("expected unsupportedCommand, got \(result)")
            return
        }
        #expect(tool == "polybridge-ctl")
        #expect(command == "status-batch")
    }

    @Test func givenAMalformedTaskEntry_whenDecoded_thenTheWholeBatchIsUnreadable() {
        // given — one entry missing its `task_id`: a compactMap would silently drop it and leave
        // the caller believing the id simply had no status.
        let stdout = json(#"{"v":11,"tasks":[{"status":"running"}],"errors":{}}"#)
        // when
        let result = CtlDocument.decodeBatchResult(stdout: stdout, stderr: "", exitCode: 0, command: "status-batch")
        // then
        guard case .failure(.unreadable) = result else {
            Issue.record("expected unreadable, got \(result)")
            return
        }
    }

    // MARK: - CtlClient.statusBatch

    @Test func givenIds_whenStatusBatchIsCalled_thenOneInvocationCarriesThemAll() async throws {
        // given
        let runner = RecordingRunner { _ in
            ok(#"{"v":11,"tasks":[],"errors":{}}"#)
        }
        let client = CtlClient(executable: "/bin/echo", environment: [:], runner: runner)

        // when
        let result = await client.statusBatch(ids: (1 ... 100).map { "task-\($0)" })

        // then — exactly one process, all 100 ids on one `--task-ids` value after `--`.
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].arguments.first == "status-batch")
        #expect(runner.calls[0].arguments.contains("--json"))
        let option = runner.calls[0].arguments.first { $0.hasPrefix("--task-ids=") }
        #expect(option?.dropFirst("--task-ids=".count).split(separator: ",").count == 100)
        let batch = try result.get()
        #expect(batch.tasks.isEmpty)
    }

    @Test func givenMoreThanOneHundredIds_whenStatusBatchIsCalled_thenOnlyTheFirstHundredAreSent() async throws {
        // given
        let runner = RecordingRunner { _ in ok(#"{"v":11,"tasks":[],"errors":{}}"#) }
        let client = CtlClient(executable: "/bin/echo", environment: [:], runner: runner)
        let ids = (1 ... 120).map { "task-\($0)" }

        // when
        _ = await client.statusBatch(ids: ids)

        // then
        let option = runner.calls[0].arguments.first { $0.hasPrefix("--task-ids=") }
        #expect(option?.dropFirst("--task-ids=".count).split(separator: ",").count == 100)
        #expect(option?.contains("task-101") == false)
    }

    @Test func givenNoIds_whenStatusBatchIsCalled_thenNoProcessRunsAndTheBatchIsEmpty() async throws {
        // given
        let runner = RecordingRunner { _ in ok(#"{"v":11,"tasks":[],"errors":{}}"#) }
        let client = CtlClient(executable: "/bin/echo", environment: [:], runner: runner)

        // when
        let result = await client.statusBatch(ids: [])

        // then
        #expect(runner.calls.isEmpty)
        let batch = try result.get()
        #expect(batch.tasks.isEmpty)
    }

    @Test func givenABatchAnswerWithMalformedErrors_whenDecoded_thenTasksStillDecodeAndBadEntriesDrop() throws {
        // given — an error entry missing its `code` cannot be classified; it is dropped rather
        // than failing the tasks that did answer (their ids simply stay "unknown outcome").
        let stdout = json(#"{"v":11,"tasks":[{"task_id":"a","status":"running","backend":"claude"}],"errors":{"x":{"message":"no code"}}}"#)
        // when
        let batch = try #require(try CtlDocument.decodeBatchResult(stdout: stdout, stderr: "", exitCode: 0, command: "status-batch").get())
        // then
        #expect(batch.tasks.map(\.taskID) == ["a"])
        #expect(batch.errors.isEmpty)
    }
}
