import Foundation
@testable import MonitorCore
import Testing

private final class StatisticsCapabilitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Bool]
    private var index = 0

    init(_ values: [Bool]) { self.values = values }

    func next() -> Bool {
        lock.withLock {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }
    }
}

struct StatisticsModelsTests {
    private func fact(_ values: [String: Any]) throws -> [String: JSONValue] {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: values)).objectValue!
    }

    private func page(_ item: [String: Any]?, state: String = "ready", more: Bool = false) throws -> [String: JSONValue] {
        var raw: [String: Any] = [
            "projection_version": 1, "state": state, "observed_at": "2026-10-27T00:00:00Z",
            "items": item.map { [$0] } ?? [], "has_more": more, "history_complete": true,
            "ownership_complete": true, "retained_history_only": true,
            "accounting_coverage": ["eligible_executions": 1, "available_executions": 0],
            "retention": ["state": "days", "days": 90]
        ]
        if state == "ready" { raw["snapshot_id"] = "snapshot"; raw["generation"] = "generation" }
        if more { raw["next_cursor"] = "next" }
        return try fact(raw)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }

    private func runner(capabilities: [Bool], answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput) -> RecordingRunner {
        let sequence = StatisticsCapabilitySequence(capabilities)
        return RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
                let optional = sequence.next() ? ",\"statistics-page.v1\"" : ""
                let response = "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                    "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                    "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                    "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                    "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\"\(optional)],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
                return ProcessOutput(exitCode: 0, stdout: json(response), stderr: "")
            }
            return answer(call)
        }
    }

    @Test func givenTwoStatisticsPages_whenRead_thenCapabilityIsProbedFreshForEachPageAndCanonicalReadyPageDecodes() async throws {
        // given
        let canonical = try #require(JSONValue.parse(fixture("ctl-statistics-page-ready"))?.objectValue? ["result"])
        let response = ctlJSON(JSONValue.object(["v": .number(1), "result": canonical]).rendered())
        let runner = runner(capabilities: [true, true]) { _ in ProcessOutput(exitCode: 0, stdout: response, stderr: "") }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let first = await client.statisticsPage(since: "start", before: "end")
        let second = await client.statisticsPage(since: "start", before: "end", cursor: "next")

        // then
        #expect(try first.get().state == "ready")
        #expect(try second.get().snapshotID == "fixture-generation")
        #expect(runner.allCalls.filter { $0.arguments == ["version-info", "--json"] }.count == 2)
        #expect(runner.calls.map(\.arguments) == [
            ["statistics-page", "--since=start", "--before=end", "--limit=100", "--json"],
            ["statistics-page", "--since=start", "--before=end", "--limit=100", "--cursor=next", "--json"]
        ])
    }

    @Test func givenCapabilityDisappearsBetweenPages_whenRead_thenSecondPageIsUnsupportedWithoutCommandLaunch() async throws {
        // given
        let canonical = try #require(JSONValue.parse(fixture("ctl-statistics-page-ready"))?.objectValue?["result"])
        let response = ctlJSON(JSONValue.object(["v": .number(1), "result": canonical]).rendered())
        let runner = runner(capabilities: [true, false]) { _ in ProcessOutput(exitCode: 0, stdout: response, stderr: "") }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let first = await client.statisticsPage(since: "start", before: "end")
        let second = await client.statisticsPage(since: "start", before: "end", cursor: "next")

        // then
        guard case .success = first else { Issue.record("The first page should pass its advertised capability"); return }
        guard case .failure(.unsupportedCommand(_, "statistics-page", _)) = second else {
            Issue.record("The fresh second-page capability check should refuse the missing feature")
            return
        }
        #expect(runner.allCalls.filter { $0.arguments == ["version-info", "--json"] }.count == 2)
        #expect(runner.calls.count == 1)
    }

    @Test func givenOlderEngineWithoutStatisticsCapability_whenRead_thenUnsupportedIsReportedWithoutPageCall() async {
        // given
        let runner = runner(capabilities: [false]) { _ in
            ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let result = await client.statisticsPage(since: "start", before: "end")

        // then
        guard case .failure(.unsupportedCommand(_, "statistics-page", _)) = result else {
            Issue.record("Older engines should return the explicit unsupported result")
            return
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenSnapshotExpiredCtlEnvelope_whenStatisticsPageRead_thenStableRefusalCodeIsPreserved() async throws {
        // given
        let raw = try #require(JSONValue.parse(fixture("ctl-statistics-snapshot-expired"))?.objectValue)
        let response = ctlJSON(JSONValue.object(raw).rendered())
        let runner = runner(capabilities: [true]) { _ in ProcessOutput(exitCode: 1, stdout: response, stderr: "") }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let result = await client.statisticsPage(since: "start", before: "end")

        // then
        guard case .failure(let error) = result else { Issue.record("Expired snapshot should be a refusal"); return }
        #expect(error.refusalCode == "snapshot_expired")
    }

    @Test func givenTerminalExecution_whenDecoded_thenDurationAndUsageQualificationRemainIndependent() throws {
        // given
        let execution: [String: Any] = ["id": "exec", "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false]

        // when
        let decoded = try #require(StatisticsFact(raw: fact(execution)))

        // then
        #expect(decoded.isSupportedTerminalFact)
        #expect(decoded.number("started_at") == 10)
        #expect(decoded.comparableTokens == nil)
    }

    @Test func givenTimedOutTerminalExecution_whenPageDecoded_thenItIsRetainedAsFinishedWork() throws {
        // given
        let execution: [String: Any] = ["id": "timed-out", "kind": "execution", "status": "timed_out", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false]

        // when
        let decoded = StatisticsPage(raw: try page(execution))

        // then
        #expect(decoded?.items.count == 1)
        #expect(decoded?.items.first?.text("status") == "timed_out")
        #expect(decoded?.items.first?.isSupportedTerminalFact == true)
        #expect(decoded?.items.first?.isFailureOutcome == true)
    }

    @Test(arguments: ["running", "unknown", "completed"])
    func givenUnsupportedOrMalformedTerminalFact_whenPageDecoded_thenOnlyValidTerminalFactsAreAccepted(status: String) throws {
        // given
        var execution: [String: Any] = ["id": "exec", "kind": "execution", "status": status, "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": true]
        if status == "completed" { execution["started_at"] = "not-a-number" }

        // when
        let decoded = StatisticsPage(raw: try page(execution))

        // then
        #expect(decoded == nil)
    }

    @Test func givenOverflowingAndInconsistentAccounting_whenFactDecoded_thenComparableTokensAreUnavailable() throws {
        // given
        let execution: [String: Any] = ["id": "exec", "kind": "execution", "status": "completed", "started_at": 1,
            "finished_at": 2, "cohort_started_at": 1, "duration_additive": true, "usage_additive": true,
            "accounting": ["version": 1, "state": "available", "scope": "execution", "additive": true,
                "total_tokens": Int.max, "categories": ["input_tokens": Int.max, "output_tokens": 1,
                    "cache_read_tokens": 0, "cache_creation_tokens": 0]]]

        // when
        let decoded = try #require(StatisticsFact(raw: fact(execution)))

        // then
        #expect(decoded.comparableTokens == nil)
        #expect(decoded.number("started_at") == 1)
        #expect(decoded.isSupportedTerminalFact)
    }

    @Test func givenNativeOwnerControlFact_whenDecoded_thenFalseContributionFlagsAndOwnerIdentitySurvive() throws {
        // given
        let native: [String: Any] = [
            "id": "execution:native-control", "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": false, "usage_additive": false,
            "owner_task_id": "task-owner", "accounting": ["version": 1, "state": "unavailable", "scope": "unknown", "additive": false]
        ]

        // when
        let decoded = try #require(StatisticsFact(raw: fact(native)))

        // then
        #expect(decoded.isSupportedTerminalFact)
        #expect(decoded.raw["duration_additive"]?.boolValue == false)
        #expect(decoded.raw["usage_additive"]?.boolValue == false)
        #expect(decoded.text("owner_task_id") == "task-owner")
        #expect(decoded.comparableTokens == nil)
    }

    @Test func givenMalformedPaginationAndCoverage_whenPageDecoded_thenPageIsRejected() throws {
        // given
        let valid = try page(nil, state: "ready", more: true)
        var missingCursor = valid; missingCursor.removeValue(forKey: "next_cursor")
        var invalidCoverage = try page(nil)
        invalidCoverage["accounting_coverage"] = .object([
            "eligible_executions": .number(1), "available_executions": .number(2)
        ])

        // when / then
        #expect(StatisticsPage(raw: missingCursor) == nil)
        #expect(StatisticsPage(raw: invalidCoverage) == nil)
    }
}
