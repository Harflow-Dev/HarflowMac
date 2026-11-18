import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowSelectedPaneTests

@Suite struct WorkflowSelectedPaneTests {

    // MARK: Header

    @Test(arguments: ["running", "completed", "failed", "needs_attention", "pending", "waiting"])
    func givenLatestAttempt_whenBadgeLabelIsRead_thenItEqualsTheCanvasLabel(status: String) {
        // given
        let header = WorkflowSelectedHeader(kind: .worker, attemptStatus: "failed", isLatestAttempt: true)
        // when
        let label = header.badgeLabel(canvasStatus: status)
        // then
        #expect(label == WorkflowNodeStatusPresentation.presentation(status: status).label)
    }

    @Test func givenOlderAttempt_whenBadgeIsRead_thenItUsesTheAttemptOwnStatus() {
        // given
        let header = WorkflowSelectedHeader(kind: .worker, attemptStatus: "failed", isLatestAttempt: false)
        // when / then
        #expect(header.badgeStatus(canvasStatus: "running") == "failed")
        #expect(header.badgeLabel(canvasStatus: "running") == WorkflowNodeStatusPresentation.presentation(status: "failed").label)
        #expect(WorkflowSelectedHeader(attemptStatus: nil, isLatestAttempt: false).badgeStatus(canvasStatus: "pending") == "pending")
    }

    @Test func givenNodeKinds_whenBuildingPresentation_thenHeaderMatchesEachKind() {
        // given
        let raw = run(activations: [worker("a1", status: "failed"), worker("a2", status: "running")])
        // when
        let latest = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "work", attemptID: nil)
        let older = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "work", attemptID: "a1")
        let orchestrator = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        // then
        #expect(latest.header == WorkflowSelectedHeader(kind: .worker, attemptStatus: "running", isLatestAttempt: true))
        #expect(older.header == WorkflowSelectedHeader(kind: .worker, attemptStatus: "failed", isLatestAttempt: false))
        #expect(orchestrator.header.kind == .orchestrator)
        #expect(orchestrator.caption == nil && orchestrator.callRows.isEmpty)
    }

    @Test func givenOnDemandNode_whenBuildingPresentation_thenHeaderCarriesOnDemandCaptionAndNoBadgeKind() {
        // given
        let raw = onDemandRun()
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: nil)
        // then
        #expect(projection.header == WorkflowSelectedHeader(kind: .onDemand, caption: "On demand"))
        #expect(!projection.showsGoal)
    }

    // MARK: Caption

    @Test func givenAllParts_whenMakingCaption_thenPartsAreJoinedWithBackendDisplayName() {
        // given / when / then
        #expect(WorkflowSelectedCaption.make(backend: "codex", model: "gpt-6", repository: "HarflowMCP") == "Codex · gpt-6 · HarflowMCP")
        #expect(WorkflowSelectedCaption.make(prefix: "Call 2", backend: "codex", model: "gpt-6", repository: "HarflowMCP")
            == "Call 2 · Codex · gpt-6 · HarflowMCP")
    }

    @Test func givenMissingParts_whenMakingCaption_thenTheyAreOmitted() {
        // given / when / then
        #expect(WorkflowSelectedCaption.make(backend: "codex", model: nil, repository: "Repo") == "Codex · Repo")
        #expect(WorkflowSelectedCaption.make(backend: "codex", model: "", repository: nil) == "Codex")
        #expect(WorkflowSelectedCaption.make(backend: nil, model: nil, repository: nil) == nil)
    }

    @Test func givenActivationCandidate_whenResolvingAgent_thenItWinsOverNodeAgentForReportedFields() {
        // given
        let activation: [String: JSONValue] = ["tasks": .array([.object(["candidate": .object(["backend": .string("claude"), "model": .string("opus")])])])]
        let node: [String: JSONValue] = ["agent": .object(["backend": .string("codex"), "model": .string("gpt-6")])]
        // when
        let reported = WorkflowSelectedCaption.agent(activation: activation, node: node)
        let partial: [String: JSONValue] = ["tasks": .array([.object(["candidate": .object(["backend": .string("claude")])])])]
        let fallback = WorkflowSelectedCaption.agent(activation: partial, node: node)
        let none = WorkflowSelectedCaption.agent(activation: nil, node: node)
        // then
        #expect(reported.backend == "claude" && reported.model == "opus")
        #expect(fallback.backend == "claude" && fallback.model == "gpt-6")
        #expect(none.backend == "codex" && none.model == "gpt-6")
    }

    @Test func givenRunWithRepoAndModel_whenBuildingWorkerPane_thenCaptionNamesBackendModelRepository() {
        // given
        var raw = run(activations: [worker("a1", status: "running")])
        raw["repo_path"] = .string("/tmp/OrbitDesk")
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "work", attemptID: nil)
        // then
        #expect(projection.caption == "Codex · gpt-6 · OrbitDesk")
    }

    @Test func givenRunWithoutGoalOrRevision_whenBuildingWorkerPane_thenGoalIsHiddenAndCaptionRemains() {
        // given
        var raw = run(activations: [worker("a1", status: "running")])
        // when
        let without = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "work", attemptID: nil)
        raw["goal"] = .string("Verify the release.")
        let with = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "work", attemptID: nil)
        // then
        #expect(!without.showsGoal)
        #expect(without.caption == "Codex · gpt-6")
        #expect(with.showsGoal)
    }

    // MARK: Call rows

    @Test func givenCalls_whenBuildingRows_thenNewestFirstWithPersistedNumbersAndActivationIDs() {
        // given
        let raw = onDemandRun()
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: nil)
        // then
        #expect(projection.callRows.map(\.id) == ["unavailable:missing", "second", "first"])
        #expect(projection.callRows.map(\.number) == [12, 9, 7])
        #expect(projection.callRows.map(\.taskID) == [nil, "task-second", "task-first"])
        #expect(projection.callRows.map(\.status) == ["failed", "running", "succeeded"])
    }

    @Test func givenUnavailableCall_whenItIsChosen_thenItSelectsWithDetailsAndNoOpenTask() {
        // given
        let raw = onDemandRun()
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: "unavailable:missing")
        // then
        #expect(projection.activationID == "unavailable:missing")
        #expect(projection.callRows.first { $0.id == "unavailable:missing" }?.taskID == nil)
        #expect(projection.callDetails?.assignment == "Check the lost call")
        #expect(projection.taskIDs.isEmpty)
        #expect(projection.caption == "Call 12 · Codex · gpt-6")
    }

    @Test func givenNeverCalledNode_whenBuildingPresentation_thenThereAreNoRows() {
        // given
        var raw = run(activations: [])
        raw["on_demand_nodes"] = .array([.object(["node_id": .string("consultant"), "title": .string("Consultant")])])
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: nil)
        // then
        #expect(projection.isOnDemand)
        #expect(projection.callRows.isEmpty)
        #expect(projection.callDetails == nil)
        #expect(projection.caption == nil)
    }

    @Test func givenSelectedCall_whenRowsAreCompared_thenSelectionChangesPresentation() {
        // given
        let raw = onDemandRun()
        // when
        let first = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: "first")
        let second = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: "second")
        // then
        #expect(first != second)
        #expect(first.activationID == "first" && second.activationID == "second")
        #expect(first.callDetails?.assignment == "Assign first" && second.callDetails?.assignment == "Assign second")
        #expect(first.caption == "Call 7 · Codex · gpt-6" && second.caption == "Call 9 · Codex · gpt-6")
        #expect(first == WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: "first"))
    }

    // MARK: Duration

    @Test func givenRunningCall_whenFormattingWithExplicitNow_thenItCountsToNow() {
        // given
        let now = Date(timeIntervalSince1970: 1072)
        // when / then
        #expect(WorkflowOnDemandCallRow.duration(startedAt: 1000, finishedAt: nil, isRunning: true, now: now) == "01:12")
        #expect(WorkflowOnDemandCallRow.duration(startedAt: 1000, finishedAt: nil, isRunning: true, now: Date(timeIntervalSince1970: 900)) == "00:00")
    }

    @Test func givenSettledOrUnknownCall_whenFormatting_thenItUsesOwnTimestampsOrNone() {
        // given
        let now = Date(timeIntervalSince1970: 9999)
        // when / then
        #expect(WorkflowOnDemandCallRow.duration(startedAt: 1000, finishedAt: 1072, isRunning: false, now: now) == "01:12")
        #expect(WorkflowOnDemandCallRow.duration(startedAt: 1000, finishedAt: 1000 + 3725, isRunning: false, now: now) == "1:02:05")
        #expect(WorkflowOnDemandCallRow.duration(startedAt: 1000, finishedAt: nil, isRunning: false, now: now) == nil)
        #expect(WorkflowOnDemandCallRow.duration(startedAt: nil, finishedAt: 1072, isRunning: false, now: now) == nil)
    }

    @Test func givenRow_whenSummarising_thenItReadsCallStatusAndDuration() {
        // given
        let row = WorkflowOnDemandCallRow(id: "x", number: 2, status: "succeeded", startedAt: 1000, finishedAt: 1072, taskID: nil)
        let unfinished = WorkflowOnDemandCallRow(id: "y", number: 3, status: "failed", startedAt: nil, finishedAt: nil, taskID: nil)
        // when / then
        #expect(row.summary(now: .now) == "Call 2 · Done · 01:12")
        #expect(unfinished.summary(now: .now) == "Call 3 · Failed")
    }

    // MARK: Approval

    @Test func givenRunApprovalState_whenMakingGate_thenMountingFollowsOptInOrPendingCount() {
        // given
        let plain: [String: JSONValue] = ["status": .string("running")]
        let optIn: [String: JSONValue] = ["status": .string("running"), "settings": .object(["caller_approvals": .bool(true)])]
        let pending: [String: JSONValue] = ["status": .string("completed"), "approval_summary": .object(["pending_count": .number(2)])]
        // when / then
        #expect(WorkflowSelectedApprovalGate.make(run: plain) == WorkflowSelectedApprovalGate(mounts: false, polls: false))
        #expect(WorkflowSelectedApprovalGate.make(run: optIn) == WorkflowSelectedApprovalGate(mounts: true, polls: true))
        #expect(WorkflowSelectedApprovalGate.make(run: pending) == WorkflowSelectedApprovalGate(mounts: true, polls: false))
    }

    @Test(arguments: ["running", "needs_attention", "needs_input"])
    func givenPollingStatus_whenGateMounts_thenItPolls(status: String) {
        // given
        let raw: [String: JSONValue] = ["status": .string(status), "caller_approvals": .bool(true)]
        // when / then
        #expect(WorkflowSelectedApprovalGate.make(run: raw).polls)
    }

    @Test(arguments: ["completed", "failed", "cancelled", "paused"])
    func givenSettledStatus_whenGateMounts_thenItDoesNotPoll(status: String) {
        // given
        let raw: [String: JSONValue] = ["status": .string(status), "caller_approvals": .bool(true)]
        // when / then
        #expect(WorkflowSelectedApprovalGate.make(run: raw) == WorkflowSelectedApprovalGate(mounts: true, polls: false))
    }

    @Test func givenOnDemandAndOrchestratorNodes_whenBuildingPresentation_thenNoApprovalMounts() {
        // given
        var raw = onDemandRun()
        raw["caller_approvals"] = .bool(true)
        // when
        let onDemand = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "consultant", attemptID: nil)
        let orchestrator = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)
        // then
        #expect(!onDemand.approval.mounts)
        #expect(!orchestrator.approval.mounts)
    }

    @Test func givenWorkerNode_whenBuildingPresentation_thenApprovalGateIsPartOfIt() {
        // given
        var raw = run(activations: [worker("a1", status: "running")])
        raw["caller_approvals"] = .bool(true)
        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "work", attemptID: nil)
        // then
        #expect(projection.approval == WorkflowSelectedApprovalGate(mounts: true, polls: false))
    }

    // MARK: Sizing

    @Test func givenTallPane_whenSizingTopRegion_thenItTakesNaturalHeightUpToHalf() {
        // given / when / then
        #expect(WorkflowSelectedPaneSizing.topRegionHeight(natural: 120, paneHeight: 800) == 120)
        #expect(WorkflowSelectedPaneSizing.topRegionHeight(natural: 700, paneHeight: 800) == 400)
    }

    @Test func givenMinimumWindowPane_whenSizingTopRegion_thenTranscriptKeepsItsFloor() {
        // given: a 620 pt window leaves roughly a 500 pt pane
        let pane: CGFloat = 500
        // when
        let region = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: pane, reserved: 56)
        let tiny = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: 120, reserved: 56)
        // then
        #expect(region == 250)
        #expect(pane - 56 - region >= WorkflowSelectedPaneSizing.transcriptFloor)
        #expect(tiny == 0)
    }

    @Test func givenApprovalPanel_whenSizingInsideColumn_thenItIsCappedAt45PercentAndFeedKeepsFloor() {
        // given / when / then
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 60, columnHeight: 500) == 60)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: 500) == 225)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: 120) == 40)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: 0) == 0)
    }

    @Test func givenMeasuredChrome_whenSizingTopRegion_thenFeedKeepsItsFloor() {
        // given: a 1000x620 window leaves about a 500 pt pane; head block 90, fallback composer 0, column chrome 150
        let pane: CGFloat = 500
        let reserved: CGFloat = 90 + 0 + 150
        // when
        let region = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: pane, reserved: reserved)
        // then
        #expect(region == 180)
        #expect(pane - reserved - region >= WorkflowSelectedPaneSizing.transcriptFloor)
    }

    @Test func givenGoalAndApproval_whenSizingBothRegionsAtMinimumWindow_thenFeedKeepsItsFloor() {
        // given: a 500 pt pane, a 90 pt head block and 100 pt of column chrome
        let pane: CGFloat = 500
        let head: CGFloat = 90
        let chrome: CGFloat = 100
        // when
        let top = WorkflowSelectedPaneSizing.topRegionHeight(natural: 100, paneHeight: pane, reserved: head + chrome)
        let column = pane - head - top
        let approval = WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: column, chrome: chrome)
        let feed = column - chrome - approval
        // then
        #expect(top == 100)
        #expect(approval == 130)
        #expect(feed == WorkflowSelectedPaneSizing.transcriptFloor)
    }

    @Test func givenTallGoalAndApproval_whenSizingAtMinimumWindow_thenGoalYieldsFirstAndApprovalCollapsesBeforeFeed() {
        // given
        let pane: CGFloat = 500
        let head: CGFloat = 90
        let chrome: CGFloat = 100
        // when
        let top = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: pane, reserved: head + chrome)
        let column = pane - head - top
        let approval = WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: column, chrome: chrome)
        // then
        #expect(top == 230)
        #expect(approval == 0)
        #expect(column - chrome - approval >= WorkflowSelectedPaneSizing.transcriptFloor)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: 190, chrome: chrome) == 10)
    }

    @Test func givenMeasuredPieces_whenDerivingChrome_thenItSumsPaddingSpacingAndPieces() {
        // given: header 40, boundary 20, divider 1, composer 60 over five children (feed included)
        // when
        let chrome = WorkflowSelectedPaneSizing.columnChrome(pieces: [40, 0, 20, 1, 0, 60], itemCount: 5)
        // then: 32 padding + 4 gaps of 10 + 121 of pieces
        #expect(chrome == 193)
        #expect(WorkflowSelectedPaneSizing.columnChrome(pieces: [-5], itemCount: 0) == 32)
    }

    @MainActor
    @Test(arguments: [true, false])
    func givenColumnModelWithApprovalGate_whenEvaluatingBody_thenItTerminatesAndSizingIsFinite(withGate: Bool) {
        // given
        let harness = ParallelVMTests()
        var model = ParallelColumnModel(
            id: "task", task: harness.task(id: "task", status: "running"), title: "Title", subtitle: "Subtitle", isBusy: false,
            outcomeMessage: "Queued", showPrompt: false, rows: [], activityRows: [], liveStep: nil,
            isLoading: false, summary: nil, onTapTakeover: nil, onTapOpenTask: {})
        model.chrome = .inspector
        model.inspectorApproval = withGate ? WorkflowSelectedApprovalGate(mounts: true, polls: true) : nil
        // when
        let view = ParallelColumnView(model: model, state: ParallelColumnUIState())
        _ = view.body
        // then
        let chrome = WorkflowSelectedPaneSizing.columnChrome(pieces: [40, 16, 20, 1, 0, 60], itemCount: 7)
        let approval = WorkflowSelectedPaneSizing.approvalHeight(natural: 300, columnHeight: 400, chrome: chrome)
        #expect(chrome.isFinite && approval.isFinite && approval >= 0)
        #expect(400 - chrome - approval >= WorkflowSelectedPaneSizing.transcriptFloor || approval == 0)
    }

    @Test(arguments: [(true, true, false, false, true), (true, true, true, false, true), (true, true, true, true, false),
                      (true, false, false, false, false), (false, true, false, false, false)])
    func givenCallState_whenDecidingDetailsPlacement_thenTheyShowOnlyWithoutAVisibleTranscript(
        _ input: (Bool, Bool, Bool, Bool, Bool)) {
        // given / when
        let shown = WorkflowCallDetails.isShown(isOnDemand: input.0, hasDetails: input.1, hasActivity: input.2, activityShowsConversation: input.3)
        // then
        #expect(shown == input.4)
    }

    @Test func givenManyCalls_whenSizingList_thenRowsCapAtFive() {
        // given / when / then
        #expect(WorkflowSelectedPaneSizing.callListHeight(rowCount: 3) == 96)
        #expect(WorkflowSelectedPaneSizing.callListHeight(rowCount: 9) == 160)
    }

    // MARK: Fixtures

    private func worker(_ id: String, status: String) -> [String: JSONValue] {
        ["id": .string(id), "node_id": .string("work"), "role": .string("node"), "status": .string(status),
         "tasks": .array([.object(["task_id": .string("task-" + id), "status": .string(status)])])]
    }

    private func run(activations: [[String: JSONValue]]) -> [String: JSONValue] {
        ["definition": .object(["nodes": .array([.object(["id": .string("work"), "type": .string("agent"),
                                                          "agent": .object(["backend": .string("codex"), "model": .string("gpt-6")])])])]),
         "activations": .array(activations.map(JSONValue.object))]
    }

    private func onDemandRun() -> [String: JSONValue] {
        var raw = run(activations: [worker("first", status: "completed"), worker("second", status: "running")])
        raw["on_demand_nodes"] = .array([.object(["node_id": .string("consultant"), "title": .string("Consultant"),
                                                 "agent": .object(["backend": .string("codex"), "model": .string("gpt-6")])])])
        raw["on_demand_calls"] = .array([
            .object(["id": .string("call-seven"), "node_id": .string("consultant"), "execution_id": .string("first"),
                     "call_number": .number(7), "status": .string("succeeded"), "assignment": .string("Assign first"), "task_id": .string("task-first"),
                     "started_at": .number(1000), "finished_at": .number(1072)]),
            .object(["id": .string("call-nine"), "node_id": .string("consultant"), "execution_id": .string("second"),
                     "call_number": .number(9), "status": .string("running"), "assignment": .string("Assign second"),
                     "task_id": .string("task-second"), "started_at": .number(1100)]),
            .object(["id": .string("missing"), "node_id": .string("consultant"), "call_number": .number(12),
                     "status": .string("failed"), "assignment": .string("Check the lost call")])
        ])
        return raw
    }
}
