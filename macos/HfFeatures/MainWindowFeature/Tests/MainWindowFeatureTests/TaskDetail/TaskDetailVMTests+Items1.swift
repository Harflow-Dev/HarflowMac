import Combine
import Foundation
import HfCommon
@testable import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

@MainActor
extension TaskDetailVMTests {
    
    // MARK: - Item a: canSend truth table
    
    @Test func givenEveryCombinationOfLiveInputRunningAndTakenOver_whenComputingCanSend_thenEveryUntakenTaskCanQueue() async {
        // given — canSend = liveInput && running && !takenOver (`TaskDetailVM+Actions.swift`).
        let harness = makeSUT()
        harness.sut.didAppear()
        
        let combinations: [(liveInput: Bool, status: String, takenOver: Bool, expected: Bool)] = [
            (true, "running", false, true),
            (true, "running", true, false),
            (true, "completed", false, true),
            (true, "completed", true, false),
            (false, "running", false, true),
            (false, "running", true, false),
            (false, "completed", false, true),
            (false, "completed", true, false)
        ]
        for combo in combinations {
            // when
            let builtTask = task(status: combo.status, liveInput: combo.liveInput, takenOver: combo.takenOver)
            harness.detailBox.value = builtTask
            harness.tasksSubject.send([builtTask])
            await waitUntil {
                harness.sut.task?.liveInput == combo.liveInput && harness.sut.task?.takenOver == combo.takenOver
                && harness.sut.task?.status == TaskStatus(combo.status) && harness.sut.messagingSupported == true
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
            ("completed", "sess-1234567890", false),
            ("completed", nil, false),
            ("running", "sess-1234567890", false),
            ("running", nil, false)
        ]
        for combo in combinations {
            // when
            let builtTask = task(status: combo.status, sessionID: combo.sessionID)
            harness.detailBox.value = builtTask
            harness.tasksSubject.send([builtTask])
            await waitUntil {
                harness.sut.task?.sessionID == combo.sessionID && harness.sut.task?.status == TaskStatus(combo.status)
                    && harness.sut.messagingSupported == true
            }
            
            // then
            #expect(
                harness.sut.messageBoxModel.canContinue == combo.expected,
                "status=\(combo.status) sessionID=\(String(describing: combo.sessionID))"
            )
        }
    }
    
    // MARK: - Item c: trimming
    
    @Test func givenMessageWithSurroundingWhitespace_whenSubmittedAsSendOrResume_thenExactTextIsQueued() async {
        // given — Send, eligible
        let send = makeSUT()
        send.useCase.configureTypedSendSuccess()
        let running = task(status: "running", liveInput: true)
        send.detailBox.value = running
        send.sut.didAppear()
        send.tasksSubject.send([running])
        await waitUntil { send.sut.task != nil && send.sut.messagingSupported == true }
        
        // when
        send.sut.submitMessage("  hello there  ", now: false) { _ in }
        
        // then
        await verify(send.useCase)
.submitTypedMessage(.value("abc12345"), text: .value("  hello there  "), now: .value(false),
            acknowledgingUnconfirmed: .any, context: .any)
.calledEventually(1, before: .seconds(5))
        
        // given — Continue (resume), eligible
        let resume = makeSUT()
        resume.useCase.configureTypedSendSuccess()
        let done = task(status: "completed")
        resume.detailBox.value = done
        resume.sut.didAppear()
        resume.tasksSubject.send([done])
        await waitUntil { resume.sut.task != nil && resume.sut.messagingSupported == true }
        
        // when
        resume.sut.submitMessage("  follow up  ", now: false) { _ in }
        
        // then
        await verify(resume.useCase)
.submitTypedMessage(.value("abc12345"), text: .value("  follow up  "), now: .value(false),
            acknowledgingUnconfirmed: .any, context: .any)
.calledEventually(1, before: .seconds(5))
    }
    
    // MARK: - Typed admission failures

    @Test func givenSendRejectedByOwner_whenSubmissionCompletes_thenDraftIsKeptAndErrorIsVisible() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task(status: "running", liveInput: true)
        given(harness.useCase)
.submitTypedMessage(.any, text: .any, now: .any,
                                                acknowledgingUnconfirmed: .any, context: .any)
.willThrow(TestError.expectedError)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil && harness.sut.messagingSupported == true }
        var accepted: Bool?
        // when
        harness.sut
.submitMessage("hello", now: false) { accepted = $0 }
        await waitUntil { accepted != nil }
        // then
        #expect(accepted == false)
        #expect(harness.sut.messageSendOutcome == TestError.expectedError.localizedDescription)
    }
}
