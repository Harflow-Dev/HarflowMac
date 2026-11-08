//
//  TaskSnapshotEvidenceTests.swift
//  MainWindowFeatureTests
//

import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskSnapshotEvidenceTests

/// The pane's Exit row and first-show default, as plain functions of the status shown and the status snapshot, if
/// any, that supports a qualifier.
@MainActor
@Suite struct TaskSnapshotEvidenceTests {
    private typealias Evidence = TaskSnapshotEvidence

    private nonisolated static let terminalStatuses: [TaskStatus] = [.completed, .failed, .timedOut, .cancelled]
    private nonisolated static let nonTerminalStatuses: [TaskStatus] = [.running, .other("pending"), .other("")]
    private nonisolated static let everyStatus: [TaskStatus] = nonTerminalStatuses + terminalStatuses
    private nonisolated static let logStates: [EventLogState?] = [nil, .open, .settling, .final, .incomplete, .unknown, .unavailable]

    /// Evidence whose snapshot is of `snapshot` (the status shown when omitted).
    private func evidence(_ status: TaskStatus, snapshot: TaskStatus? = nil, takenOver: Bool = false,
                          exit: Int? = nil, logState: EventLogState? = nil) -> Evidence {
        Evidence(status: status, takenOver: takenOver, snapshotStatus: snapshot ?? status, exitCode: exit, logState: logState)
    }

    private func noSnapshot(_ status: TaskStatus, exit: Int? = nil, logState: EventLogState? = nil) -> Evidence {
        Evidence(status: status, takenOver: false, snapshotStatus: nil, exitCode: exit, logState: logState)
    }

    // MARK: - hasMatchingSnapshot

    @Test(arguments: everyStatus)
    func givenEachStatus_whenTheSnapshotHasTheSameStatus_thenItMatches(status: TaskStatus) {
        // given / when / then
        #expect(evidence(status).hasMatchingSnapshot)
    }

    @Test func givenNoSnapshotOrAnotherStatus_whenAsked_thenItDoesNotMatch() {
        // given / when / then
        #expect(!noSnapshot(.completed).hasMatchingSnapshot)
        #expect(!evidence(.completed, snapshot: .running).hasMatchingSnapshot)
        #expect(!evidence(.other("pending"), snapshot: .other("queued")).hasMatchingSnapshot)
    }

    // MARK: - exitText, with a matching snapshot

    @Test(arguments: terminalStatuses, [0, 1, 137, -9])
    func givenATerminalStatusWithAnObservedExit_whenReadingTheExit_thenTheCodeIsShown(status: TaskStatus, code: Int) {
        // given / when
        let text = evidence(status, exit: code).exitText

        // then
        #expect(text == String(code))
    }

    @Test(arguments: nonTerminalStatuses, [0, 1])
    func givenANonTerminalStatus_whenTheSnapshotCarriesAnExit_thenTheExitIsADash(status: TaskStatus, code: Int) {
        // given / when / then
        #expect(evidence(status, exit: code).exitText == "—")
        #expect(evidence(status).exitText == "—")
    }

    @Test(arguments: logStates)
    func givenADoneTaskWithoutAnExit_whenReadingTheExit_thenItIsNotObservedWhateverTheLogState(logState: EventLogState?) {
        // given / when / then
        #expect(evidence(.completed, logState: logState).exitText == "Not observed")
    }

    @Test func givenAFailedTaskWithoutAnExit_whenTheLogIsIncomplete_thenItIsNotObserved() {
        // given / when / then
        #expect(evidence(.failed, logState: .incomplete).exitText == "Not observed")
    }

    @Test(arguments: logStates.filter { $0 != .incomplete })
    func givenAFailedTaskWithoutAnExit_whenTheLogIsAnythingButIncomplete_thenItIsADash(logState: EventLogState?) {
        // given / when / then
        #expect(evidence(.failed, logState: logState).exitText == "—")
    }

    @Test(arguments: [TaskStatus.timedOut, .cancelled], logStates)
    func givenATimedOutOrCancelledTaskWithoutAnExit_whenReadingTheExit_thenItIsAlwaysADash(status: TaskStatus, logState: EventLogState?) {
        // given / when / then
        #expect(evidence(status, logState: logState).exitText == "—")
    }

    @Test func givenAFailedTaskWithAnExitAndAnIncompleteLog_whenReadingTheExit_thenTheCodeWins() {
        // given / when / then
        #expect(evidence(.failed, exit: 2, logState: .incomplete).exitText == "2")
    }

    @Test func givenADoneTaskWithAZeroExit_whenReadingTheExit_thenZeroIsShownNotADash() {
        // given / when / then
        #expect(evidence(.completed, exit: 0).exitText == "0")
    }

    // MARK: - exitText, without matching evidence

    @Test(arguments: everyStatus, logStates)
    func givenNoSnapshot_whenReadingTheExit_thenItIsADashWhateverElseIsKnown(status: TaskStatus, logState: EventLogState?) {
        // given / when / then
        #expect(noSnapshot(status, exit: 0, logState: logState).exitText == "—")
        #expect(noSnapshot(status, logState: logState).exitText == "—")
    }

    @Test(arguments: terminalStatuses)
    func givenASnapshotOfAnotherStatus_whenReadingTheExit_thenItNeverSupportsAQualifier(status: TaskStatus) {
        // given
        let other: TaskStatus = status == .running ? .completed : .running

        // when
        let text = evidence(status, snapshot: other, exit: 0, logState: .incomplete).exitText

        // then
        #expect(text == "—")
    }

    // MARK: - paneDefault

    @Test(arguments: [TaskStatus.running, .failed, .timedOut, .cancelled, .other("pending")], [true, false])
    func givenAnyStatusButDone_whenResolvingTheDefault_thenItIsReadyAndClosedWithOrWithoutASnapshot(status: TaskStatus, hasSnapshot: Bool) {
        // given
        let subject = hasSnapshot ? evidence(status, exit: 0, logState: .final) : noSnapshot(status, exit: 0, logState: .final)

        // when
        let input = subject.paneDefault

        // then
        #expect(input == .init(isReady: true, opensAtSplit: false))
    }

    @Test func givenADoneTaskWithoutASnapshot_whenResolvingTheDefault_thenItWaits() {
        // given / when / then
        #expect(noSnapshot(.completed, exit: 0).paneDefault == .init())
        #expect(!noSnapshot(.completed).paneDefault.isReady)
    }

    @Test func givenADoneTaskWithASnapshotOfAnotherStatus_whenResolvingTheDefault_thenItStillWaits() {
        // given
        let subject = evidence(.completed, snapshot: .running, exit: 0)

        // when / then
        #expect(subject.paneDefault == .init())
    }

    @Test func givenADoneTaskWhoseSnapshotObservedAnExit_whenResolvingTheDefault_thenItOpensAtSplit() {
        // given / when / then
        #expect(evidence(.completed, exit: 0).paneDefault == .init(isReady: true, opensAtSplit: true))
        #expect(evidence(.completed, exit: 1).paneDefault == .init(isReady: true, opensAtSplit: true))
    }

    @Test func givenADoneTaskWhoseSnapshotObservedNoExit_whenResolvingTheDefault_thenItIsReadyAndClosed() {
        // given / when / then
        #expect(evidence(.completed).paneDefault == .init(isReady: true, opensAtSplit: false))
    }

    @Test(arguments: [true, false], [Int?.none, 0])
    func givenATakenOverDoneTask_whenResolvingTheDefault_thenItIsClosedBeforeTheDoneBranchEvenWithoutASnapshot(hasSnapshot: Bool, exit: Int?) {
        // given
        let subject = Evidence(status: .completed, takenOver: true, snapshotStatus: hasSnapshot ? .completed : nil,
                               exitCode: exit, logState: .final)

        // when / then
        #expect(subject.paneDefault == .init(isReady: true, opensAtSplit: false))
    }

    @Test(arguments: logStates)
    func givenAnyLogState_whenResolvingTheDefault_thenItDoesNotChangeTheDefault(logState: EventLogState?) {
        // given
        let done = evidence(.completed, exit: 0, logState: logState)
        let failed = evidence(.failed, logState: logState)

        // when / then
        #expect(done.paneDefault == .init(isReady: true, opensAtSplit: true))
        #expect(failed.paneDefault == .init(isReady: true, opensAtSplit: false))
    }

    @Test func givenTheDefaultInput_whenCreatedEmpty_thenItIsNotReady() {
        // given / when
        let input = TaskPaneController.DefaultInput()

        // then
        #expect(!input.isReady)
        #expect(!input.opensAtSplit)
    }
}

// MARK: - TaskFactsText

@MainActor
@Suite struct TaskFactsTextTests {
    private func task(_ fields: [String: JSONValue]) throws -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string("abc12345"), "backend": .string("claude"), "status": .string("completed")]
        object.merge(fields) { _, new in new }
        return try #require(TaskInfo(.object(object)))
    }

    @Test func givenATakenOverTask_whenReadingTheStatus_thenTheQualifierIsAppended() throws {
        // given / when / then
        #expect(TaskFactsText.status(try task(["taken_over": .bool(true)])) == "Done · taken over")
        #expect(TaskFactsText.status(try task(["taken_over": .bool(false)])) == "Done")
        #expect(TaskFactsText.status(try task(["status": .string("timed_out")])) == "Timed out")
    }

    @Test func givenARepoPath_whenReadingTheRepository_thenItIsTheFolderNameOrADashWhenEmpty() throws {
        // given / when / then
        #expect(TaskFactsText.repository(try task(["repo_path": .string("/Users/example/repo")])) == "repo")
        #expect(TaskFactsText.repository(try task(["repo_path": .string("")])) == "—")
    }

    @Test func givenTurns_whenReading_thenTheFirstTurnIsOne() {
        // given / when / then
        #expect(TaskFactsText.turns(nil) == "1")
        #expect(TaskFactsText.turns("3 turns") == "3 turns")
    }
}

// MARK: - TaskDetailViewModel.snapshotEvidence

extension TaskDetailVMTests {

    private func rawTask(status: String, exit: Int? = nil) -> TaskInfo {
        var raw = task(status: status).raw
        if let exit { raw["exit_code"] = .number(Double(exit)) }
        return TaskInfo(.object(raw))!
    }

    private func frame(logState: EventLogState?, taskID: String = "abc12345") -> EventObservationFrame {
        EventObservationFrame(taskID: taskID, scope: FeatureObservationFixture.scope, logState: logState)
    }

    @Test func givenNoTask_whenReadingTheSnapshotEvidence_thenItIsNil() {
        // given
        let harness = makeSUT()

        // when / then
        #expect(harness.sut.snapshotEvidence == nil)
    }

    @Test func givenAListingRowOnly_whenReadingTheSnapshotEvidence_thenNoQualifierIsSupported() async {
        // given
        let harness = makeSUT()
        let listed = rawTask(status: "failed", exit: 1)
        harness.detailBox.value = listed
        harness.sut.didAppear()
        harness.tasksSubject.send([listed])
        await waitUntil { harness.sut.inspectorModel != nil }
        harness.sut.observationFrames["abc12345"] = frame(logState: .incomplete)

        // when
        let evidence = harness.sut.snapshotEvidence

        // then — the row's exit code is not a snapshot's.
        #expect(evidence?.snapshotStatus == nil)
        #expect(evidence?.exitCode == nil)
        #expect(evidence?.exitText == "—")
        #expect(evidence?.logState == .incomplete)
    }

    @Test func givenASnapshotOfTheStatusShown_whenReadingTheSnapshotEvidence_thenItCarriesTheExitAndTheFramesLogState() async {
        // given
        let harness = makeSUT()
        let listed = rawTask(status: "failed")
        harness.detailBox.value = listed
        harness.snapshotBox.value = rawTask(status: "failed")
        harness.sut.didAppear()
        harness.tasksSubject.send([listed])
        await waitUntil { harness.sut.inspectorModel?.hasSnapshot == true }
        harness.sut.observationFrames["abc12345"] = frame(logState: .incomplete)

        // when
        let evidence = harness.sut.snapshotEvidence

        // then
        #expect(evidence?.status == .failed)
        #expect(evidence?.snapshotStatus == .failed)
        #expect(evidence?.exitCode == nil)
        #expect(evidence?.logState == .incomplete)
        #expect(evidence?.exitText == "Not observed")
    }

    @Test func givenASnapshotWithAnExit_whenReadingTheSnapshotEvidence_thenTheExitIsShown() async {
        // given
        let harness = makeSUT()
        let listed = rawTask(status: "completed")
        harness.detailBox.value = listed
        harness.snapshotBox.value = rawTask(status: "completed", exit: 0)
        harness.sut.didAppear()
        harness.tasksSubject.send([listed])
        await waitUntil { harness.sut.inspectorModel?.hasSnapshot == true }

        // when
        let evidence = harness.sut.snapshotEvidence

        // then
        #expect(evidence?.exitText == "0")
        #expect(evidence?.paneDefault == .init(isReady: true, opensAtSplit: true))
    }

    @Test func givenAFrameOfAnotherTask_whenReadingTheSnapshotEvidence_thenItsLogStateIsIgnored() async {
        // given
        let harness = makeSUT()
        let listed = rawTask(status: "failed")
        harness.detailBox.value = listed
        harness.sut.didAppear()
        harness.tasksSubject.send([listed])
        await waitUntil { harness.sut.inspectorModel != nil }
        harness.sut.observationFrames = ["someone-else": frame(logState: .incomplete, taskID: "someone-else")]

        // when / then
        #expect(harness.sut.snapshotEvidence?.logState == nil)
    }
}
