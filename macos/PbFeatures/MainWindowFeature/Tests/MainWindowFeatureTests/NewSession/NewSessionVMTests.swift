import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTestUtilities
import PbUI
import Testing

@MainActor
@Suite struct NewSessionVMTests {

    private func makeSUT(catalog: BackendCatalog = .empty) -> (
        sut: NewSessionVM, useCase: MockNewSessionUseCase, routing: MockNewSessionRouting, catalogSubject: PassthroughSubject<BackendCatalog, Never>
    ) {
        let useCase = MockNewSessionUseCase()
        let routing = MockNewSessionRouting()
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        given(useCase).backendCatalog.willReturn(catalog)
        given(useCase).backendCatalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        return (sut, useCase, routing, catalogSubject)
    }

    private func catalog(_ entries: [(String, Bool?)], state: BackendCatalogState = .available) -> BackendCatalog {
        BackendCatalog(entries: entries.map { BackendCatalogEntry(backend: $0.0, installed: $0.1) }, state: state)
    }

    // MARK: - Defaults (headless-only)

    @Test func givenDefaults_whenTheSheetOpens_thenClaudeReadOnlyAndEmptyFieldsShow() {
        // given / when — the catalog hasn't reported yet (`.empty` = `.loading`), so the picker
        // falls back to `BackendStyle.known`, whose first entry is "claude" (Design's New Session
        // section: this fallback, not a hardcoded default, is why "claude" is still what shows).
        let (sut, _, _, _) = makeSUT()

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
        let (sut, _, _, _) = makeSUT()
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
        let (sut, _, _, _) = makeSUT()
        sut.didChangeMessage("do the thing")
        #expect(sut.repo.isEmpty)

        // then
        #expect(sut.canStart == false)
    }

    // MARK: - Repo path validation (exact copy)

    @Test func givenARelativeOrMissingPath_whenStarted_thenTheExactValidationTextIsShown() {
        // given
        let (sut, useCase, _, _) = makeSUT()
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
        let (sut, useCase, routing, _) = makeSUT()
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
        let (sut, useCase, _, _) = makeSUT()
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
        let (sut, _, routing, _) = makeSUT()
        given(routing).chooseDirectory().willReturn("/tmp/chosen")

        // when
        sut.didTapChooseDirectory()

        // then
        await waitUntil { sut.repo == "/tmp/chosen" }
        #expect(sut.repo == "/tmp/chosen")
    }

    @Test func givenChooseDirectoryIsCancelled_whenTapped_thenRepoIsUnchanged() async {
        // given
        let (sut, _, routing, _) = makeSUT()
        given(routing).chooseDirectory().willReturn(nil)
        sut.didChangeRepo("/tmp/existing")

        // when — wait for the mocked call to actually be recorded (not a fixed sleep) before
        // asserting the negative, so a `didTapChooseDirectory()` that silently did nothing would
        // fail this test instead of passing vacuously.
        sut.didTapChooseDirectory()
        await verify(routing).chooseDirectory().calledEventually(1, before: .seconds(5))

        // then
        #expect(sut.repo == "/tmp/existing")
    }

    // MARK: - Cancel

    @Test func givenCancelTapped_whenCalled_thenRoutingDismissIsCalled() {
        // given
        let (sut, _, routing, _) = makeSUT()
        given(routing).dismiss().willReturn()

        // when
        sut.didTapCancel()

        // then
        verify(routing).dismiss().called(1)
    }

    // MARK: - Backend catalog (Monitor piece 6)

    @Test func givenAnAvailableCatalog_whenTheSheetOpens_thenTheAgentPickerListsItInOrder() {
        // given / when
        let (sut, _, _, _) = makeSUT(catalog: catalog([("claude", true), ("codex", false), ("vibe", true)]))

        // then
        #expect(sut.agentOptions.map(\.id) == ["claude", "codex", "vibe"])
        #expect(sut.agentOptions.map(\.isNotFound) == [false, true, false])
        #expect(sut.backend == "claude")
        #expect(sut.agentListUnavailableNote == nil)
    }

    @Test func givenANotFoundBackendSelected_whenRead_thenTheInlineNoteAppearsAndDisappears() {
        // given
        let (sut, _, _, _) = makeSUT(catalog: catalog([("claude", true), ("codex", false)]))
        #expect(sut.agentNotFoundNote == nil)

        // when
        sut.didChangeBackend("codex")

        // then
        #expect(sut.agentNotFoundNote == "codex wasn't found on your PATH — starting it may fail.")

        // when — switching back to a found backend clears it.
        sut.didChangeBackend("claude")

        // then
        #expect(sut.agentNotFoundNote == nil)
    }

    @Test func givenADegradedCatalogWithNoEntries_whenTheSheetOpens_thenItFallsBackToTheKnownBackendsWithANote() {
        // given / when
        let (sut, _, _, _) = makeSUT(catalog: BackendCatalog(entries: [], state: .degraded))

        // then
        #expect(sut.agentOptions.map(\.id) == BackendStyle.known)
        #expect(sut.agentOptions.allSatisfy { !$0.isNotFound })
        #expect(sut.agentListUnavailableNote == "Backend list unavailable — update polybridge.")
        #expect(sut.backend == BackendStyle.known.first)
    }

    @Test func givenTheCatalogIsStillLoading_whenTheSheetOpens_thenItFallsBackToTheKnownBackendsWithNoNote() {
        // given / when — `.empty` is `.loading`.
        let (sut, _, _, _) = makeSUT(catalog: .empty)

        // then
        #expect(sut.agentOptions.map(\.id) == BackendStyle.known)
        #expect(sut.agentListUnavailableNote == nil)
    }

    // MARK: - Selection reconciliation (Review round 2)

    @Test func givenTheSelectedBackendStaysInANewCatalog_whenReplaced_thenSelectionIsKept() async {
        // given
        let (sut, _, _, catalogSubject) = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        sut.didAppear()
        sut.didChangeBackend("codex")
        #expect(sut.backend == "codex")

        // when — a fresh catalog still lists codex, just reordered/extended.
        catalogSubject.send(catalog([("vibe", true), ("codex", true), ("claude", true)]))

        // then
        await waitUntil { sut.agentOptions.map(\.id) == ["vibe", "codex", "claude"] }
        #expect(sut.backend == "codex")
    }

    @Test func givenTheSelectedBackendLeavesTheCatalog_whenReplaced_thenSelectionFallsToTheFirstEntry() async {
        // given
        let (sut, _, _, catalogSubject) = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        sut.didAppear()
        sut.didChangeBackend("codex")
        #expect(sut.backend == "codex")

        // when — codex is gone from the new catalog.
        catalogSubject.send(catalog([("vibe", true), ("claude", true)]))

        // then
        await waitUntil { sut.backend == "vibe" }
        #expect(sut.backend == "vibe")
    }

    @Test func givenAnEmptySuccessfulCatalog_whenReplaced_thenBackendClearsAndStartDisables() async {
        // given
        let (sut, _, _, catalogSubject) = makeSUT(catalog: catalog([("claude", true)]))
        sut.didAppear()
        sut.didChangeRepo("/tmp")
        sut.didChangeMessage("do the thing")
        #expect(sut.canStart == true)

        // when — polybridge itself reports no registered backends at all.
        catalogSubject.send(BackendCatalog(entries: [], state: .available))

        // then — never submits an invisible backend.
        await waitUntil { sut.backend.isEmpty }
        #expect(sut.backend.isEmpty)
        #expect(sut.canStart == false)
    }
}
