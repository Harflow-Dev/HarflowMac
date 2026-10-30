import Combine
import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - NeedsYouRepositoryImplTests

@Suite struct NeedsYouRepositoryImplTests {
    private func engine(_ roots: [(String, [String: JSONValue])]) -> FakeNeedsYouEngine {
        let fake = FakeNeedsYouEngine()
        fake.headers = roots.map { rootHeader($0.0) }
        for (id, status) in roots { fake.statuses[id] = status }
        return fake
    }

    @Test func givenDeadCaller_whenPassRuns_thenQuestionIsListedAndSnapshotIsReady() async throws {
        // given
        let fake = engine([("w1", treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))])
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(sut.snapshot.phase == .ready)
        #expect(item.id == "input:w1:d1" && item.kind == .question && item.ownership.callerEnded)
        #expect(item.startedBy == "Original caller" && item.rootRunID == "w1" && item.text == "Which target?")
    }

    @Test(arguments: [
        ("caller", "alive", false), ("caller", "unknown", false), ("caller", "dead", false),
        ("future", "dead", true), ("monitor", "alive", false)
    ])
    func givenEngineStatesNotAvailable_whenPassRuns_thenNothingIsListed(owner: String, caller: String, available: Bool) async {
        // given
        let state = interaction(owner: owner, caller: caller, available: available)
        let fake = engine([("w1", treeRoot("w1", state: state, selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))])
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty)
    }

    @Test func givenMonitorOwnedWithoutHandover_whenPassRuns_thenStartedByMacApp() async throws {
        // given
        let state = interaction(owner: "monitor", caller: "alive")
        let sut = makeSUT(engine([("w1", treeRoot("w1", state: state, selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))]))
        // when
        await sut.runPass()
        // then
        #expect(try #require(sut.snapshot.items.first).startedBy == "Mac app")
    }

    @Test func givenHandover_whenPassRuns_thenRecordIsKeptAndStartedByIsOriginalCaller() async throws {
        // given
        let state = interaction(owner: "monitor", handover: true)
        let sut = makeSUT(engine([("w1", treeRoot("w1", state: state, selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))]))
        // when
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(item.ownership.handover?.reason == "pid_absent" && item.startedBy == "Original caller")
    }

    @Test func givenMissingInteractionState_whenPassRuns_thenUnsupportedWithoutUnreadableCount() async {
        // given
        var status = treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")])
        status["interaction_state"] = nil
        let sut = makeSUT(engine([("w1", status)]))
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty && sut.snapshot.workflowInputsUnsupported && sut.snapshot.unreadableSourceCount == 0)
    }

    @Test func givenChildSourcedEntries_whenPassRuns_thenKeyedByRootAndPathIsResolved() async throws {
        // given
        let entry = inputEntry(run: "child", decision: "dc", path: ["w1", "child"])
        let sut = makeSUT(engine([("w1", treeRoot("w1", selected: "dc", inputs: [entry]))]))
        // when
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(item.id == "input:w1:dc" && item.rootRunID == "w1" && item.sourceRunID == "child")
        #expect(item.pathTitles == ["Release", "Name child", "Node"])
    }

    @Test func givenSelectedCheckpointResumeNotAllowed_whenPassRuns_thenOnlySiblingIsListed() async {
        // given
        let inputs = [inputEntry(run: "w1", decision: "sel", since: 1), inputEntry(run: "w1", decision: "sib", since: 2)]
        let sut = makeSUT(engine([("w1", treeRoot("w1", selected: "sel", inputs: inputs, controls: controls(resume: false)))]))
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.map(\.id) == ["input:w1:sib"])
    }

    @Test func givenPlainRoot_whenPassRuns_thenQuestionAndUsageLimitChoicesAreRead() async throws {
        // given
        let status: [String: JSONValue] = [
            "workflow_run_id": .string("w1"), "name": .string("Plain"), "status": .string("needs_input"), "interaction_state": interaction(),
            "monitor_controls": controls(), "input_question": .string("Retry?"), "input_decision_id": .string("d1"),
            "usage_limit_recovery": .object(["decision_id": .string("d1"), "choices": .array([.object(["answer": .string("retry")])])])
        ]
        let sut = makeSUT(engine([("w1", status)]))
        // when
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(item.id == "input:w1:d1" && item.offeredAnswers == ["retry"])
    }

    @Test func givenChildUsageLimit_whenPassRuns_thenChoicesComeFromTheSourceRead() async throws {
        // given
        let entry = inputEntry(run: "child", decision: "dc", path: ["w1", "child"], kind: "usage_limit")
        let fake = engine([("w1", treeRoot("w1", selected: "dc", inputs: [entry]))])
        fake.statuses["child"] = ["workflow_run_id": .string("child"),
                                  "usage_limit_recovery": .object(["decision_id": .string("dc"), "choices": .array([.object(["answer": .string("switch")])])])]
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(try #require(sut.snapshot.items.first).offeredAnswers == ["switch"])
        #expect(fake.calls.contains("status:child"))
    }

    @Test func givenWorkerUsageLimit_whenPassRuns_thenItIsFreeTextWithTheHint() async throws {
        // given
        var entry = try #require(inputEntry(run: "child", decision: "dc", path: ["w1", "child"], kind: "usage_limit").objectValue)
        entry["resume_hint"] = .string("pick")
        let fake = engine([("w1", treeRoot("w1", selected: "dc", inputs: [.object(entry)]))])
        fake.statuses["child"] = ["workflow_run_id": .string("child")]
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(item.offeredAnswers == nil && item.resumeHint == "pick" && sut.snapshot.unreadableSourceCount == 0)
    }

    @Test func givenAttentionRoot_whenPassRuns_thenOneRecoveryWithReasonFingerprint() async throws {
        // given
        let attention = JSONValue.object(["workflow_run_id": .string("w1"), "status": .string("needs_attention"), "reason": .string("limit"),
                                          "path": .array([.string("w1")]), "waiting_since": .number(5)])
        let status = treeRoot("w1", status: "needs_attention", attention: [attention], extra: ["attention_reason": .string("limit")])
        let fake = engine([("w1", status)])
        fake.headers = [rootHeader("w1", status: "needs_attention")]
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(item.kind == .recovery && item.canAddAttempts && item.text == "limit")
        #expect(item.id == "attention:w1:w1:\(NeedsYouMapper.fingerprint("limit"))")
    }

    @Test func givenBuilderAndChildHeaders_whenPassRuns_thenTheyAreNotRead() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("b", kind: "builder"), rootHeader("c", parent: "w1"), rootHeader("r", status: "running")]
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(!fake.calls.contains { $0.hasPrefix("status:") })
    }

    @Test func givenMoreThanOneHundredHeaders_whenPassRuns_thenLaterPagesAreRead() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.headers = (0 ..< 120).map { rootHeader("w\($0)", status: $0 == 115 ? "needs_input" : "running") }
        fake.statuses["w115"] = treeRoot("w115", selected: "d", inputs: [inputEntry(run: "w115", decision: "d")])
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.map(\.id) == ["input:w115:d"])
        #expect(fake.calls.filter { $0 == "workflowPage" }.count == 2)
    }

    @Test func givenManyCandidates_whenPassesRun_thenReadsRotateFairlyWithinBudget() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.headers = (0 ..< 30).map { rootHeader(String(format: "w%02d", $0)) }
        for header in fake.headers {
            let id = header["workflow_run_id"]!.stringValue!
            fake.statuses[id] = treeRoot(id, selected: "d", inputs: [inputEntry(run: id, decision: "d")])
        }
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        let firstPass = fake.calls.count
        await sut.runPass()
        await sut.runPass()
        // then
        #expect(firstPass <= NeedsYouCore.invocationBudget)
        #expect(Set(fake.calls.filter { $0.hasPrefix("status:") }).count == 30)
        #expect(sut.snapshot.items.count == 30 && sut.snapshot.phase == .ready)
    }

    @Test func givenHugeInventory_whenPassRuns_thenInvocationCountStaysWithinBudget() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.pageSize = 2
        fake.headers = (0 ..< 400).map { rootHeader("w\($0)", status: "running") }
        fake.tasks = (0 ..< 400).map { awaitingTask("t\($0)", awaiting: 0) }
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(fake.calls.count <= NeedsYouCore.invocationBudget)
        #expect(sut.snapshot.deferredSourceCount > 0 && sut.snapshot.phase == .loading)
    }

    @Test func givenUnreadableRoot_whenPassRuns_thenItIsCountedAndItsItemsAreWithdrawnNotResolved() async throws {
        // given
        let fake = engine([("w1", treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))])
        let sut = makeSUT(fake)
        let events = LockedBox<[NeedsYouEvent]>([])
        let token = sut.eventsPublisher().sink { event in events.mutate { $0.append(event) } }
        await sut.runPass()
        #expect(sut.snapshot.items.count == 1)
        // when
        fake.failingStatuses = ["w1"]
        await sut.runPass()
        let withdrawn = sut.snapshot
        fake.failingStatuses = []
        await sut.runPass()
        // then
        #expect(withdrawn.items.isEmpty && withdrawn.unreadableSourceCount == 1 && withdrawn.isLowerBound)
        #expect(sut.snapshot.items.count == 1 && sut.snapshot.unreadableSourceCount == 0)
        #expect(!events.value.contains { if case .resolved = $0 { true } else { false } })
        #expect(events.value.count == 1)
        token.cancel()
    }

    @Test func givenStartup_whenItemsAreFirstObserved_thenTheyAreBaselineAndLaterOnesAreNot() async {
        // given
        let fake = engine([("w1", treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))])
        let sut = makeSUT(fake)
        let events = LockedBox<[NeedsYouEvent]>([])
        let token = sut.eventsPublisher().sink { event in events.mutate { $0.append(event) } }
        // when
        await sut.runPass()
        fake.statuses["w1"] = treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1"), inputEntry(run: "w1", decision: "d2")])
        await sut.runPass()
        fake.statuses["w1"] = treeRoot("w1", selected: "d2", inputs: [inputEntry(run: "w1", decision: "d2")])
        await sut.runPass()
        // then
        let flags = events.value.compactMap { event -> Bool? in if case .appeared(_, let baseline) = event { baseline } else { nil } }
        #expect(flags == [true, false])
        #expect(events.value.contains(.resolved("input:w1:d1")))
        token.cancel()
    }

    @Test func givenAliveCallerThenDead_whenPassesRun_thenItArrivesAsNonBaseline() async throws {
        // given
        let alive = interaction(owner: "caller", caller: "alive", available: false)
        let fake = engine([("w1", treeRoot("w1", state: alive, selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))])
        let sut = makeSUT(fake)
        let events = LockedBox<[NeedsYouEvent]>([])
        let token = sut.eventsPublisher().sink { event in events.mutate { $0.append(event) } }
        await sut.runPass()
        #expect(sut.snapshot.items.isEmpty)
        // when
        fake.statuses["w1"] = treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")])
        await sut.runPass()
        // then
        #expect(events.value.count == 1)
        if case .appeared(_, let baseline)? = events.value.first { #expect(!baseline) } else { Issue.record("expected an appeared event") }
        token.cancel()
    }

    @Test func givenRootLeavesInventory_whenInventoryCompletes_thenItsItemsResolve() async {
        // given
        let fake = engine([("w1", treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))])
        let sut = makeSUT(fake)
        await sut.runPass()
        // when
        fake.headers = []
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty)
    }

    @Test func givenItemsOldestFirst_whenPublished_thenOrderedByWaitingSinceThenID() async {
        // given
        let inputs = [inputEntry(run: "w1", decision: "b", since: 20), inputEntry(run: "w1", decision: "a", since: 20),
                      inputEntry(run: "w1", decision: "c", since: 5)]
        let sut = makeSUT(engine([("w1", treeRoot("w1", selected: "a", inputs: inputs))]))
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.map(\.decisionID) == ["c", "a", "b"])
    }

    @Test func givenUnchangedEngine_whenPassesRepeat_thenSnapshotPublishesOnce() async {
        // given
        let sut = makeSUT(engine([("w1", treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")]))]))
        let count = LockedBox(0)
        let token = sut.snapshotPublisher().sink { _ in count.mutate { $0 += 1 } }
        // when
        await sut.runPass()
        let afterFirst = count.value
        await sut.runPass()
        await sut.runPass()
        // then
        #expect(count.value == afterFirst)
        token.cancel()
    }

    @Test func givenInventoryFailureBeforeReady_whenPassRuns_thenStillLoading() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.workflowPageFails = true
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.phase == .loading && sut.snapshot.unreadableSourceCount == 1)
    }
}
