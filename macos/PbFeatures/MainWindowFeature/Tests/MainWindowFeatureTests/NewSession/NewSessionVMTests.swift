import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTerminal
import PbTestUtilities
import Testing

@MainActor
@Suite struct NewSessionVMTests {
    
    /// Never `.start()`ed — a "started" session fixture with no real process.
    private func session() throws -> TerminalSession {
        try TerminalSession(
            kind: .interactive, title: "claude · repo", backend: "claude",
            command: TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
    }
    
    private func makeSUT() -> (sut: NewSessionVM, useCase: MockNewSessionUseCase, routing: MockNewSessionRouting) {
        let useCase = MockNewSessionUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        return (sut, useCase, routing)
    }
    
    // MARK: - Defaults (MS-NS-1)
    
    @Test func givenDefaults_whenTheSheetOpens_thenClaudeInteractiveReadOnlyAndEmptyFieldsShow() {
        // given / when
        let (sut, _, _) = makeSUT()
        
        // then
        #expect(sut.backend == "claude")
        #expect(sut.interactive == true)
        #expect(sut.freedom == "read_only")
        #expect(sut.repo == "")
        #expect(sut.message == "")
        #expect(sut.errorText == nil)
        #expect(sut.isMessageFieldDisabled == true)
    }
    
    // MARK: - Start-button enable rules
    
    @Test func givenInteractiveModeWithARepo_whenCanStartIsRead_thenTheMessageIsIgnored() {
        // given
        let (sut, _, _) = makeSUT()
        
        // when
        sut.didChangeRepo("/tmp/repo")
        
        // then — interactive mode never requires a message
        #expect(sut.canStart == true)
    }
    
    @Test func givenHeadlessModeWithABlankMessage_whenCanStartIsRead_thenItIsFalse() {
        // given
        let (sut, _, _) = makeSUT()
        sut.didChangeInteractive(false)
        sut.didChangeRepo("/tmp/repo")
        
        // then
        #expect(sut.canStart == false)
        
        // when
        sut.didChangeMessage("do the thing")
        
        // then
        #expect(sut.canStart == true)
    }
    
    @Test func givenAnEmptyRepo_whenCanStartIsRead_thenItIsFalseRegardlessOfMode() {
        // given — every other condition satisfied (headless with a non-blank message), so the only
        // thing left to make `canStart` false is the empty repo itself.
        let (sut, _, _) = makeSUT()
        sut.didChangeInteractive(false)
        sut.didChangeMessage("do the thing")
        #expect(sut.repo.isEmpty)
        
        // then
        #expect(sut.canStart == false)
    }
    
    @Test func givenInteractiveToggled_whenReadingIsMessageFieldDisabled_thenItTracksInteractive() {
        // given — positive setup: `interactive` defaults to `true`, so the field starts disabled.
        let (sut, _, _) = makeSUT()
        #expect(sut.isMessageFieldDisabled == true)
        
        // when
        sut.didChangeInteractive(false)
        
        // then — proves the property actually tracks the toggle, not just a static default.
        #expect(sut.isMessageFieldDisabled == false)
    }
    
    // MARK: - Repo path validation (MS-NS-1, exact copy)
    
    @Test func givenARelativeOrMissingPath_whenStarted_thenTheExactValidationTextIsShown() {
        // given
        let (sut, useCase, routing) = makeSUT()
        given(useCase).resolvedRepoPath(.any).willReturn(nil)
        given(routing).didStartInteractive(sessionID: .any).willReturn()
        sut.didChangeRepo("relative/path")
        
        // when
        sut.didTapStart()
        
        // then
        #expect(sut.errorText == "Choose an existing folder.")
        verify(routing).didStartInteractive(sessionID: .any).called(0)
    }
    
    // MARK: - Interactive start
    
    @Test func givenInteractiveStartSucceeds_whenCompleted_thenRoutingDidStartInteractiveIsCalled() throws {
        // given
        let (sut, useCase, routing) = makeSUT()
        let startedSession = try session()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).startInteractive(backend: .any, repo: .any).willReturn(.success(startedSession))
        given(routing).didStartInteractive(sessionID: .any).willReturn()
        sut.didChangeRepo("/tmp/repo")
        
        // when
        sut.didTapStart()
        
        // then
        verify(routing).didStartInteractive(sessionID: .value(startedSession.id)).called(1)
        #expect(sut.errorText == nil)
    }
    
    @Test func givenInteractiveStartFails_whenCompleted_thenTheErrorStaysInline() {
        // given
        let (sut, useCase, routing) = makeSUT()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).startInteractive(backend: .any, repo: .any).willReturn(.failure(StartInteractiveError(message: "Could not start claude: boom")))
        sut.didChangeRepo("/tmp/repo")
        
        // when
        sut.didTapStart()
        
        // then
        #expect(sut.errorText == "Could not start claude: boom")
        verify(routing).didStartInteractive(sessionID: .any).called(0)
    }
    
    // MARK: - Headless run
    
    @Test func givenAHeadlessStartSucceeds_whenCompleted_thenRoutingDidStartIsCalled() async {
        // given
        let (sut, useCase, routing) = makeSUT()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).run(.any).willReturn("new-task-id")
        given(routing).didStart(taskID: .any).willReturn()
        sut.didChangeInteractive(false)
        sut.didChangeRepo("/tmp/repo")
        sut.didChangeMessage("do the thing")
        
        // when
        sut.didTapStart()
        
        // then — `isStarting` flips synchronously, then clears once the (mocked, immediate) run
        // completes; `waitUntil` times out silently, so the condition is asserted again afterward.
        #expect(sut.isStarting == true)
        await waitUntil { sut.isStarting == false }
        #expect(sut.isStarting == false)
        verify(routing).didStart(taskID: .value("new-task-id")).called(1)
        #expect(sut.errorText == nil)
    }
    
    @Test func givenAHeadlessStartFails_whenCompleted_thenTheErrorStaysInlineAndNothingIsDismissed() async {
        // given
        let (sut, useCase, routing) = makeSUT()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).run(.any).willThrow(ToolError.notFound(tool: "polybridge-ctl", searched: []))
        sut.didChangeInteractive(false)
        sut.didChangeRepo("/tmp/repo")
        sut.didChangeMessage("do the thing")
        
        // when
        sut.didTapStart()
        
        // then
        #expect(sut.isStarting == true)
        await waitUntil { sut.isStarting == false }
        #expect(sut.isStarting == false)
        #expect(sut.errorText != nil)
        verify(routing).didStart(taskID: .any).called(0)
    }
    
    // MARK: - Directory chooser (AppKit lives in the coordinator, not here)
    
    @Test func givenChooseDirectoryReturnsAPath_whenTapped_thenRepoUpdates() async {
        // given
        let (sut, _, routing) = makeSUT()
        given(routing).chooseDirectory().willReturn("/tmp/chosen")
        
        // when
        sut.didTapChooseDirectory()
        
        // then
        await waitUntil { sut.repo == "/tmp/chosen" }
        #expect(sut.repo == "/tmp/chosen")
    }
    
    @Test func givenChooseDirectoryIsCancelled_whenTapped_thenRepoIsUnchanged() async {
        // given
        let (sut, _, routing) = makeSUT()
        given(routing).chooseDirectory().willReturn(nil)
        sut.didChangeRepo("/tmp/existing")
        
        // when — wait for the mocked call to actually be recorded (not a fixed sleep) before
        // asserting the negative, so a `didTapChooseDirectory()` that silently did nothing would
        // fail this test instead of passing vacuously.
        sut.didTapChooseDirectory()
        await verify(routing).chooseDirectory().calledEventually(1, before: .seconds(1))
        
        // then
        #expect(sut.repo == "/tmp/existing")
    }
    
    // MARK: - Cancel
    
    @Test func givenCancelTapped_whenCalled_thenRoutingDismissIsCalled() {
        // given
        let (sut, _, routing) = makeSUT()
        given(routing).dismiss().willReturn()
        
        // when
        sut.didTapCancel()
        
        // then
        verify(routing).dismiss().called(1)
    }
}
