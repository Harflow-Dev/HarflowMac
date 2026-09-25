import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTerminal
import PbTestUtilities
import Testing

@MainActor
@Suite struct InteractiveVMTests {
    
    private func session(kind: TerminalSession.Kind = .interactive) throws -> TerminalSession {
        try TerminalSession(kind: kind, title: "claude", backend: "claude", command: TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:]))
    }
    
    private func makeSUT(sessionID: UUID) -> (
        sut: InteractiveVM, useCase: MockInteractiveUseCase, routing: MockInteractiveRouting,
        sessionsSubject: PassthroughSubject<[TerminalSession], Never>
    ) {
        let useCase = MockInteractiveUseCase()
        let routing = MockInteractiveRouting()
        let sessionsSubject = PassthroughSubject<[TerminalSession], Never>()
        given(useCase).sessionsPublisher().willReturn(sessionsSubject.eraseToAnyPublisher())
        given(useCase).removeSession(.any).willReturn()
        let sut = InteractiveVM(sessionID: sessionID, useCase: useCase, routing: routing)
        return (sut, useCase, routing, sessionsSubject)
    }
    
    // MARK: - Session lookup
    
    @Test func givenNoSubscriptionYet_whenCreated_thenSessionIsNil() {
        // given
        let harness = makeSUT(sessionID: UUID())
        
        // then
        #expect(harness.sut.session == nil)
    }
    
    @Test func givenAMatchingSession_whenSessionsPublish_thenSessionIsSet() async throws {
        // given
        let matching = try session()
        let other = try session()
        let harness = makeSUT(sessionID: matching.id)
        
        // when
        harness.sut.didAppear()
        harness.sessionsSubject.send([other, matching])
        
        // then
        await waitUntil { harness.sut.session === matching }
        #expect(harness.sut.session === matching)
    }
    
    @Test func givenTheMatchingSessionDisappearsFromTheList_whenPublished_thenSessionBecomesNil() async throws {
        // given — positive setup first: the session really was found, so its disappearance below
        // proves the pipeline reacted rather than matching a VM that never found it in the first
        // place.
        let matching = try session()
        let other = try session()
        let harness = makeSUT(sessionID: matching.id)
        harness.sut.didAppear()
        harness.sessionsSubject.send([matching])
        await waitUntil { harness.sut.session === matching }
        
        // when
        harness.sessionsSubject.send([other])
        
        // then
        await waitUntil { harness.sut.session == nil }
        #expect(harness.sut.session == nil)
    }
    
    // MARK: - didAppear / didDisappear (root AGENTS.md rule 7)
    
    @Test func givenDidAppearCalledTwice_whenObserved_thenItSubscribesOnlyOnce() {
        // given
        let harness = makeSUT(sessionID: UUID())
        
        // when
        harness.sut.didAppear()
        harness.sut.didAppear()
        
        // then
        verify(harness.useCase).sessionsPublisher().called(1)
    }
    
    @Test func givenDidDisappear_whenTheViewReappears_thenItSubscribesAgain() async throws {
        // given
        let matching = try session()
        let harness = makeSUT(sessionID: matching.id)
        harness.sut.didAppear()
        harness.sessionsSubject.send([matching])
        await waitUntil { harness.sut.session === matching }
        
        // when
        harness.sut.didDisappear()
        harness.sut.didAppear()
        
        // then — a fresh subscription was made (a second call to `sessionsPublisher()`), so the
        // (brand-new) subject still delivers.
        verify(harness.useCase).sessionsPublisher().called(2)
    }
    
    @Test func givenDidDisappear_whenTheOldPublisherStillEmits_thenItIsIgnored() async throws {
        // given — proves teardown actually cancels the subscription, not merely that a later one
        // works: the *same* subject that used to update `session` must no longer be able to after
        // `didDisappear()`.
        let matching = try session()
        let other = try session()
        let harness = makeSUT(sessionID: matching.id)
        harness.sut.didAppear()
        harness.sessionsSubject.send([matching])
        await waitUntil { harness.sut.session === matching }
        harness.sut.didDisappear()
        
        // when
        harness.sessionsSubject.send([other])
        try? await Task.sleep(for: .milliseconds(100))
        
        // then — still the stale value from before teardown, never nil (which the missing-match
        // branch would have set had the subscription still been live).
        #expect(harness.sut.session === matching)
    }
    
    // MARK: - Terminal pane end/close (mirrors `TaskDetailVMTests`' item s)
    
    @Test func givenATerminalSession_whenEndingIt_thenTerminatingBecomesTrueSynchronously() async throws {
        // given
        let live = try session()
        live.start()
        let harness = makeSUT(sessionID: live.id)
        harness.sut.didAppear()
        harness.sessionsSubject.send([live])
        await waitUntil { harness.sut.session === live }
        #expect(!live.terminating)
        
        // when
        harness.sut.didTapEndSession()
        
        // then — flips synchronously; the actual reap happens off the main queue.
        #expect(live.terminating)
        
        // cleanup: let the real child actually finish tearing down before the test ends.
        await waitUntil { live.ended }
    }
    
    @Test func givenATerminalSession_whenClosingIt_thenRemoveSessionIsCalledWithIt() async throws {
        // given
        let live = try session()
        let harness = makeSUT(sessionID: live.id)
        harness.sut.didAppear()
        harness.sessionsSubject.send([live])
        await waitUntil { harness.sut.session === live }
        
        // when
        harness.sut.didTapCloseSession()
        
        // then
        verify(harness.useCase).removeSession(.any).called(1)
    }
    
    @Test func givenNoSession_whenEndingOrClosing_thenNothingHappens() {
        // given
        let harness = makeSUT(sessionID: UUID())
        harness.sut.didAppear()
        
        // when — no crash, and no session to forward to `removeSession`.
        harness.sut.didTapEndSession()
        harness.sut.didTapCloseSession()
        
        // then
        verify(harness.useCase).removeSession(.any).called(0)
    }
}
