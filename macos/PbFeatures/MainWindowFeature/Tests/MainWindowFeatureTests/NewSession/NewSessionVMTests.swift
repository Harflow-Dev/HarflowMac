import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

@MainActor
@Suite struct NewSessionVMTests {

    private func makeSUT() -> (sut: NewSessionVM, useCase: MockNewSessionUseCase, routing: MockNewSessionRouting) {
        let useCase = MockNewSessionUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        return (sut, useCase, routing)
    }

    // MARK: - Defaults (headless-only)

    @Test func givenDefaults_whenTheSheetOpens_thenClaudeReadOnlyAndEmptyFieldsShow() {
        // given / when
        let (sut, _, _) = makeSUT()

        // then
        #expect(sut.backend == "claude")
        #expect(sut.freedom == "read_only")
        #expect(sut.repo == "")
        #expect(sut.message == "")
        #expect(sut.errorText == nil)
    }

    // MARK: - Start-button enable rules

    @Test func givenABlankMessage_whenCanStartIsRead_thenItIsFalse() {
        // given
        let (sut, _, _) = makeSUT()
        sut.didChangeRepo("/tmp/repo")

        // then — a non-blank message is required to start
        #expect(sut.canStart == false)

        // when
        sut.didChangeMessage("do the thing")

        // then
        #expect(sut.canStart == true)
    }

    @Test func givenAnEmptyRepo_whenCanStartIsRead_thenItIsFalse() {
        // given — every other condition satisfied (a non-blank message), so the only thing left to
        // make `canStart` false is the empty repo itself.
        let (sut, _, _) = makeSUT()
        sut.didChangeMessage("do the thing")
        #expect(sut.repo.isEmpty)

        // then
        #expect(sut.canStart == false)
    }

    // MARK: - Repo path validation (exact copy)

    @Test func givenARelativeOrMissingPath_whenStarted_thenTheExactValidationTextIsShown() {
        // given
        let (sut, useCase, _) = makeSUT()
        given(useCase).resolvedRepoPath(.any).willReturn(nil)
        sut.didChangeRepo("relative/path")
        sut.didChangeMessage("do the thing")

        // when
        sut.didTapStart()

        // then
        #expect(sut.errorText == "Choose an existing folder.")
    }

    // MARK: - Headless run

    @Test func givenAHeadlessStartSucceeds_whenCompleted_thenRoutingDidStartIsCalled() async {
        // given
        let (sut, useCase, routing) = makeSUT()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).run(.any).willReturn("new-task-id")
        given(routing).didStart(taskID: .any).willReturn()
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
        let (sut, useCase, _) = makeSUT()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).run(.any).willThrow(ToolError.notFound(tool: "polybridge-ctl", searched: []))
        sut.didChangeRepo("/tmp/repo")
        sut.didChangeMessage("do the thing")

        // when
        sut.didTapStart()

        // then
        #expect(sut.isStarting == true)
        await waitUntil { sut.isStarting == false }
        #expect(sut.isStarting == false)
        #expect(sut.errorText != nil)
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
