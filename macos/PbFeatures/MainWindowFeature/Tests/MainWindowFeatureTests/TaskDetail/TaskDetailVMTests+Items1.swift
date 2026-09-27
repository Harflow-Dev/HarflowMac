import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor
extension TaskDetailVMTests {
    
    // MARK: - Item a: canSend truth table
    
    @Test func givenEveryCombinationOfLiveInputRunningAndTakenOver_whenComputingCanSend_thenOnlyAllThreeTogetherEnableIt() async {
        // given — canSend = liveInput && running && !takenOver (`TaskDetailVM+Actions.swift`).
        let harness = makeSUT()
        harness.sut.didAppear()
        
        let combinations: [(liveInput: Bool, status: String, takenOver: Bool, expected: Bool)] = [
            (true, "running", false, true),
            (true, "running", true, false),
            (true, "completed", false, false),
            (true, "completed", true, false),
            (false, "running", false, false),
            (false, "running", true, false),
            (false, "completed", false, false),
            (false, "completed", true, false)
        ]
        for combo in combinations {
            // when
            let builtTask = task(status: combo.status, liveInput: combo.liveInput, takenOver: combo.takenOver)
            harness.detailBox.value = builtTask
            harness.tasksSubject.send([builtTask])
            await waitUntil {
                harness.sut.task?.liveInput == combo.liveInput && harness.sut.task?.takenOver == combo.takenOver
                && harness.sut.task?.status == TaskStatus(combo.status)
            }
            
            // then
            #expect(
                harness.sut.messageBoxModel.canSend == combo.expected,
                "liveInput=\(combo.liveInput) status=\(combo.status) takenOver=\(combo.takenOver)"
            )
        }
    }
    
    // MARK: - Item b: canContinue truth table
    
    @Test func givenEveryCombinationOfTerminalStatusAndSessionID_whenComputingCanContinue_thenOnlyTerminalWithASessionEnablesIt() async {
        // given — canContinue = status.isTerminal && sessionID != nil (`TaskDetailVM+Actions.swift`).
        let harness = makeSUT()
        harness.sut.didAppear()
        
        let combinations: [(status: String, sessionID: String?, expected: Bool)] = [
            ("completed", "sess-1234567890", true),
            ("completed", nil, false),
            ("running", "sess-1234567890", false),
            ("running", nil, false)
        ]
        for combo in combinations {
            // when
            let builtTask = task(status: combo.status, sessionID: combo.sessionID)
            harness.detailBox.value = builtTask
            harness.tasksSubject.send([builtTask])
            await waitUntil { harness.sut.task?.sessionID == combo.sessionID && harness.sut.task?.status == TaskStatus(combo.status) }
            
            // then
            #expect(
                harness.sut.messageBoxModel.canContinue == combo.expected,
                "status=\(combo.status) sessionID=\(String(describing: combo.sessionID))"
            )
        }
    }
    
    // MARK: - Item c: trimming
    
    @Test func givenMessageWithSurroundingWhitespace_whenSubmittedAsSendOrResume_thenBothAreTrimmedBeforeDispatch() async {
        // given — Send, eligible
        let send = makeSUT()
        let running = task(status: "running", liveInput: true)
        send.detailBox.value = running
        send.sut.didAppear()
        send.tasksSubject.send([running])
        await waitUntil { send.sut.task != nil }
        
        // when
        #expect(send.sut.submitMessage("  hello there  "))
        
        // then
        await verify(send.useCase).send(.value("abc12345"), text: .value("hello there")).calledEventually(1, before: .seconds(1))
        
        // given — Continue (resume), eligible
        let resume = makeSUT()
        let done = task(status: "completed")
        resume.detailBox.value = done
        resume.sut.didAppear()
        resume.tasksSubject.send([done])
        await waitUntil { resume.sut.task != nil }
        
        // when
        #expect(resume.sut.submitMessage("  follow up  "))
        
        // then
        await verify(resume.useCase).resume(.value("abc12345"), text: .value("follow up"), onResumed: .any).calledEventually(1, before: .seconds(1))
    }
    
    // MARK: - Item d: the busy guard rejecting the action still clears the text
    
    @Test func givenSendWillBeRejectedByTheBusyGuard_whenAnEligibleMessageIsSubmitted_thenTheTextStillClearsImmediately() async {
        // given — a standalone fixture (not `makeSUT()`) so `send` can be stubbed to throw from the
        // very first call, standing in for `TaskActionRepository`'s own busy check-and-insert
        // refusing it. The settled plan is explicit: the field clears "even if ... the busy guard
        // rejects it" (`2026-09-25-monitor-architecture-plan-settled.md:172`).
        let useCase = MockTaskDetailUseCase()
        let routing = MockTaskDetailRouting()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        given(useCase).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(PassthroughSubject<Bool, Never>().eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(PassthroughSubject<[String: String], Never>().eraseToAnyPublisher())
        given(useCase).snapshotsPublisher().willReturn(PassthroughSubject<[String: TaskInfo], Never>().eraseToAnyPublisher())
        given(useCase).busyPublisher().willReturn(PassthroughSubject<Set<String>, Never>().eraseToAnyPublisher())
        given(useCase).outcomesPublisher().willReturn(PassthroughSubject<[String: String], Never>().eraseToAnyPublisher())
        given(useCase).itemsPublisher(for: .any).willReturn(PassthroughSubject<[TimelineItem], Never>().eraseToAnyPublisher())
        
        let running = task(status: "running", repoPath: "", liveInput: true)
        given(useCase).detail(.any).willReturn(running)
        given(useCase).title(.any).willReturn("Task abc12345")
        given(useCase).ancestors(of: .any).willReturn([])
        given(useCase).conversationMembers(of: .any).willReturn([running])
        given(useCase).children(of: .any).willReturn([])
        given(useCase).siblings(of: .any).willReturn([])
        given(useCase).snapshot(.any).willReturn(nil)
        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn("abc12345")
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.any).willReturn(lease)
        given(useCase).items(for: .any).willReturn([])
        given(useCase).events(for: .any).willReturn([])
        given(useCase).eventsAvailability(for: .any).willReturn(.available)
        given(useCase).eventsAvailabilityPublisher(for: .any).willReturn(PassthroughSubject<EventAvailability, Never>().eraseToAnyPublisher())
        given(useCase).eventsPath(for: .any).willReturn("/dev/null")
        given(useCase).activity(for: .any).willReturn(ActivityCounts())
        given(useCase).current(for: .any).willReturn(nil)
        given(useCase).prompt(for: .any).willReturn(nil)
        given(useCase).send(.any, text: .any).willThrow(TestError.expectedError)
        
        let sut = TaskDetailVM(taskID: "abc12345", useCase: useCase, routing: routing)
        sut.didAppear()
        tasksSubject.send([running])
        await waitUntil { sut.task != nil }
        
        // when
        let cleared = sut.submitMessage("hello")
        
        // then — clears synchronously; the dispatch's own (here: rejected) outcome never reaches
        // this return, because it is decided before the `Task { }` closure ever runs.
        #expect(cleared)
        await verify(useCase).send(.value("abc12345"), text: .value("hello")).calledEventually(1, before: .seconds(1))
    }
    
    // MARK: - Item e: default tab
    
    @Test func givenAFreshVM_whenNoTabHasBeenSelected_thenTimelineIsTheDefaultTab() {
        // given / when
        let harness = makeSUT()
        
        // then
        #expect(harness.sut.tab == .timeline)
    }
    
}
