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

    private func runner(
        capabilities: [Bool],
        costCapabilities: [Bool] = [false],
        answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput
    ) -> RecordingRunner {
        let sequence = StatisticsCapabilitySequence(capabilities)
        let costSequence = StatisticsCapabilitySequence(costCapabilities)
        return RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
                let optional = sequence.next() ? ",\"statistics-page.v1\"" : ""
                let cost = costSequence.next() ? ",\"statistics-cost-model.v1\"" : ""
                let response = "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                    "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                    "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                    "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                    "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\"\(optional)\(cost)],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
                return ProcessOutput(exitCode: 0, stdout: json(response), stderr: "")
            }
            return answer(call)
        }
    }

    @Test func givenCostCapabilityAndReportedZero_whenStatisticsPageRead_thenOneFreshHandshakeQualifiesCost() async throws {
        // given
        var raw = try page([
            "id": "execution:zero", "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false,
            "execution_kind": "initial", "task_id": "zero", "cost_usd": 0,
            "cost_provenance": "backend_reported", "cost_additive": true
        ])
        raw["cost_coverage"] = .object(["eligible_executions": .number(1), "available_executions": .number(1)])
        let response = ctlJSON(JSONValue.object(["v": .number(1), "result": .object(raw)]).rendered())
        let runner = runner(capabilities: [true], costCapabilities: [true]) { _ in
            ProcessOutput(exitCode: 0, stdout: response, stderr: "")
        }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let page = try #require(try await client.statisticsPage(since: "start", before: "end").get())

        // then
        #expect(page.costQualified)
        #expect(page.costCoverage == StatisticsCostCoverage(eligibleExecutions: 1, availableExecutions: 1))
        #expect(page.items.first?.reportedCost == .reported(0))
        #expect(runner.allCalls.filter { $0.arguments == ["version-info", "--json"] }.count == 1)
    }

    @Test func givenVendoredReportedAndSilentCostPage_whenReadWithCostCapability_thenAllThreeExecutionFactsRemainTyped() async throws {
        // given
        let response = try fixture("ctl-statistics-page-cost-reported-and-silent")
        let runner = runner(capabilities: [true], costCapabilities: [true]) { _ in
            ProcessOutput(exitCode: 0, stdout: response, stderr: "")
        }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let page = try #require(try await client.statisticsPage(since: "start", before: "end").get())
        let costs = Dictionary(uniqueKeysWithValues: page.items.map { ($0.text("task_id") ?? "", $0.reportedCost) })

        // then
        #expect(page.costCoverage == StatisticsCostCoverage(eligibleExecutions: 3, availableExecutions: 2))
        #expect(costs["cost-reported"] == .reported(0.4321))
        #expect(costs["cost-silent"] == .unavailable)
        #expect(costs["cost-mixed-model"] == .reported(1.5))
    }

    @Test func givenOldEngineCostFields_whenStatisticsPageRead_thenBasePageStaysAvailableAndCostIsUnqualified() async throws {
        // given
        var raw = try page([
            "id": "execution:old", "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false,
            "execution_kind": "initial", "task_id": "old", "cost_usd": 8.5,
            "cost_provenance": "backend_reported", "cost_additive": true
        ])
        raw["cost_coverage"] = .object(["eligible_executions": .number(1), "available_executions": .number(1)])
        let response = ctlJSON(JSONValue.object(["v": .number(1), "result": .object(raw)]).rendered())
        let runner = runner(capabilities: [true], costCapabilities: [false]) { _ in
            ProcessOutput(exitCode: 0, stdout: response, stderr: "")
        }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let page = try #require(try await client.statisticsPage(since: "start", before: "end").get())

        // then
        #expect(!page.costQualified)
        #expect(page.costCoverage == nil)
        #expect(page.items.first?.reportedCost == .unqualified)
        #expect(runner.calls.map(\.arguments).contains(["statistics-page", "--since=start", "--before=end", "--limit=100", "--json"]))
    }

    @Test func givenCostCapability_whenExecutionKindIsUnknownOrCostFieldsDisagree_thenCostQualificationFailsClosed() throws {
        // given
        func raw(_ executionKind: String, cost: Any = 1.25, provenance: Any = "backend_reported", additive: Any = true) throws -> [String: JSONValue] {
            try fact([
                "id": "execution:test", "kind": "execution", "status": "completed", "started_at": 10,
                "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false,
                "execution_kind": executionKind, "task_id": "test", "cost_usd": cost,
                "cost_provenance": provenance, "cost_additive": additive
            ])
        }

        // when
        let unknownKind = StatisticsFact(raw: try raw("future"), costQualified: true)
        let negative = StatisticsFact(raw: try raw("initial", cost: -1), costQualified: true)
        let nativeConflict = StatisticsFact(raw: try raw("native"), costQualified: true)
        let native = StatisticsFact(raw: try raw("native", cost: NSNull(), provenance: NSNull(), additive: false), costQualified: true)

        // then
        #expect(unknownKind.reportedCost == .invalid)
        #expect(negative.reportedCost == .invalid)
        #expect(nativeConflict.reportedCost == .invalid)
        #expect(native.reportedCost == .excluded)
    }

    @Test(arguments: ["initial", "resume", "continuation", "control"])
    func givenRecognizedTaskExecutionKind_whenReportedCostIsValid_thenContributionIsAvailable(executionKind: String) throws {
        // given
        let raw = try fact([
            "id": "execution:" + executionKind, "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false,
            "execution_kind": executionKind, "task_id": "task-" + executionKind, "cost_usd": 2.125,
            "cost_provenance": "backend_reported", "cost_additive": true
        ])

        // when
        let decoded = StatisticsFact(raw: raw, costQualified: true)

        // then
        #expect(decoded.reportedCost == .reported(2.125))
    }

    @Test func givenEligibleExecutionLacksTaskIdentityOrHasUnknownProvenance_whenQualified_thenCostIsInvalid() throws {
        // given
        var missingIdentity = try fact([
            "id": "execution:missing-task", "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false,
            "execution_kind": "resume", "cost_usd": 1, "cost_provenance": "backend_reported", "cost_additive": true
        ])
        let unknownProvenance = try fact([
            "id": "execution:unknown-provenance", "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false,
            "execution_kind": "control", "task_id": "control", "cost_usd": 1, "cost_provenance": "estimated", "cost_additive": true
        ])
        var missingAdditivity = try fact([
            "id": "execution:missing-additivity", "kind": "execution", "status": "completed", "started_at": 10,
            "finished_at": 20, "cohort_started_at": 10, "duration_additive": true, "usage_additive": false,
            "execution_kind": "control", "task_id": "control", "cost_usd": 1,
            "cost_provenance": "backend_reported", "cost_additive": true
        ])
        missingIdentity.removeValue(forKey: "task_id")
        missingAdditivity.removeValue(forKey: "cost_additive")

        // when
        let missingTask = StatisticsFact(raw: missingIdentity, costQualified: true)
        let unknownCost = StatisticsFact(raw: unknownProvenance, costQualified: true)
        let missingFlag = StatisticsFact(raw: missingAdditivity, costQualified: true)

        // then
        #expect(missingTask.reportedCost == .invalid)
        #expect(unknownCost.reportedCost == .invalid)
        #expect(missingFlag.reportedCost == .invalid)
    }

    @Test func givenMalformedCostCoverage_whenQualifiedPageDecoded_thenTimePageSurvivesWithoutCostCoverage() throws {
        // given
        var raw = try page(nil)
        raw["cost_coverage"] = .object(["eligible_executions": .number(1), "available_executions": .number(2)])

        // when
        let decoded = StatisticsPage(raw: raw, costQualified: true)

        // then
        #expect(decoded != nil)
        #expect(decoded?.costQualified == true)
        #expect(decoded?.costCoverage == nil)
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

    @Test func givenCostCapabilityChangesBetweenPages_whenRead_thenBothBasePagesRemainAvailableWithSeparateQualification() async throws {
        // given
        let canonical = try #require(JSONValue.parse(fixture("ctl-statistics-page-ready"))?.objectValue?["result"])
        let response = ctlJSON(JSONValue.object(["v": .number(1), "result": canonical]).rendered())
        let runner = runner(capabilities: [true, true], costCapabilities: [true, false]) { _ in
            ProcessOutput(exitCode: 0, stdout: response, stderr: "")
        }
        let client = CtlClient(executable: "/fake/harflow-ctl", environment: [:], runner: runner)

        // when
        let first = try #require(try await client.statisticsPage(since: "start", before: "end").get())
        let second = try #require(try await client.statisticsPage(since: "start", before: "end", cursor: "next").get())

        // then
        #expect(first.costQualified)
        #expect(!second.costQualified)
        #expect(first.state == "ready")
        #expect(second.state == "ready")
        #expect(runner.allCalls.filter { $0.arguments == ["version-info", "--json"] }.count == 2)
        #expect(runner.calls.count == 2)
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
