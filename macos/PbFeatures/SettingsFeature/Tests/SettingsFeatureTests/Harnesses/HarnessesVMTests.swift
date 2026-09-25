import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct HarnessesVMTests {
    
    private static func document(_ json: String) -> SetupDocument {
        // Feeds `makeSUT`'s default parameter value below, where Swift disallows `try` entirely —
        // this JSON is a fixed literal that cannot fail to decode.
        // swiftlint:disable:next force_try
        try! SetupDocument.decode(stdout: Data(json.utf8), stderr: "", exitCode: 0).get()
    }
    
    private func document(_ json: String) -> SetupDocument {
        Self.document(json)
    }
    
    private static let emptyDocumentJSON = #"{"v":1,"clients":[]}"#
    
    private var twoRowsJSON: String {
        #"""
        {"v":1,"server_path":"/usr/local/bin/polybridge","clients":[
            {"key":"claude-code","available":true,"installed":true,"current":true},
            {"key":"codex","available":true,"installed":false}
        ]}
        """#
    }
    
    private static let setupClient = SetupClient(executable: "/bin/polybridge-setup", environment: [:])
    
    private func makeSUT(
        status: Result<SetupDocument, ToolError> = .success(HarnessesVMTests.document(HarnessesVMTests.emptyDocumentJSON)),
        locate: Result<SetupClient, ToolError> = .success(HarnessesVMTests.setupClient)
    ) -> (sut: HarnessesVM, useCase: MockHarnessesUseCase) {
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(status)
        given(useCase).locate().willReturn(locate)
        let sut = HarnessesVM(useCase: useCase)
        return (sut, useCase)
    }
    
    /// `publishViewEvent`/`publishDialog` (`PbCommon.ViewModel`) dispatch via `Task { @MainActor in
    /// ... }`, not synchronously — so a subscriber set up just before the call can still see `nil`
    /// immediately after it returns. Every dialog-observing test below waits for the event to land
    /// before reading it, and — per `waitUntil`'s own contract ("it times out silently, so always
    /// `#expect` the condition afterwards") — always asserts the awaited condition explicitly rather
    /// than trusting the wait alone.
    private func waitForDialog(_ sut: HarnessesVM, publish: () -> Void) async -> (dialog: AlertContent, cancellable: AnyCancellable) {
        var published: AlertContent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { event in
            if case .dialog(let dialog) = event { published = dialog }
        }
        publish()
        await waitUntil { published != nil }
        return (published!, cancellable)
    }
    
    // MARK: - Loading
    
    @Test func givenAppear_whenStatusSucceeds_thenRowsAndServerPathLoad() async {
        // given
        let (sut, _) = makeSUT(status: .success(document(twoRowsJSON)))
        
        // when
        sut.didAppear()
        
        // then
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.serverPath == "/usr/local/bin/polybridge")
        #expect(sut.errorMessage == nil)
    }
    
    @Test func givenAppear_whenStatusFails_thenTheErrorMessageIsSet() async {
        // given
        let failure = ToolError.notFound(tool: "polybridge-setup", searched: ["/usr/local/bin"])
        let (sut, _) = makeSUT(status: .failure(failure))
        
        // when
        sut.didAppear()
        
        // then
        await waitUntil { sut.errorMessage != nil }
        #expect(sut.errorMessage == failure.message)
        #expect(sut.rows.isEmpty)
    }
    
    @Test func givenALoadCompletes_whenObserved_thenIsLoadingEndsFalseAndRefreshIsNotDisabled() async {
        // given — Mockable's generated `willProduce` for an `async` member takes a synchronous
        // producer (confirmed against the framework source: `FunctionReturnBuilder.willProduce`
        // has no suspending overload), so `status()`/`perform()` cannot be held open from a test to
        // observe `isLoading`/`workingKey` mid-flight without flakiness. This test instead checks
        // the settled state `isRefreshDisabled` is derived from, which is what actually matters.
        let (sut, _) = makeSUT(status: .success(document(twoRowsJSON)))
        
        // when
        sut.didAppear()
        
        // then — positive setup first: the load genuinely completed (rows populated), so the
        // settled-state checks below prove something actually finished rather than matching a VM
        // that never loaded at all.
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.isLoading == false)
        #expect(sut.workingKey == nil)
        #expect(sut.isRefreshDisabled == false)
    }
    
    // MARK: - Install / Remove dialog
    
    @Test func givenDidTapInstall_whenPublished_thenTheDialogCopyMatchesTheOldConfirmation() async {
        // given
        let (sut, _) = makeSUT()
        let row = document(twoRowsJSON).rows[1] // codex, not installed
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstall(row) }
        
        // then
        #expect(dialog.title == "Install polybridge into \(row.displayName)?")
        #expect(dialog.description == "This runs polybridge-setup, which edits \(row.displayName)'s own configuration.")
        #expect(dialog.actions.first?.title == "Install")
        withExtendedLifetime(cancellable) {}
    }
    
    @Test func givenDidTapRemove_whenPublished_thenTheDialogCopyMatchesTheOldConfirmation() async {
        // given
        let (sut, _) = makeSUT()
        let row = document(twoRowsJSON).rows[0] // claude-code, installed
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        
        // then
        #expect(dialog.title == "Remove polybridge from \(row.displayName)?")
        #expect(dialog.description == "This runs polybridge-setup, which edits \(row.displayName)'s own configuration.")
        #expect(dialog.actions.first?.title == "Remove")
        #expect(dialog.actions.first?.role == nil) // the original Button had no role
        withExtendedLifetime(cancellable) {}
    }
    
    @Test func givenAHarnessActionSucceeds_whenCompleted_thenOnlyThatRowUpdates() async {
        // given — existing issue, preserved: the other row must be untouched by the action's result.
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        let installedDocument = document(#"""
        {"v":1,"clients":[{"key":"codex","available":true,"installed":true,"current":true,"action":"install"}]}
        """#)
        given(useCase).perform(.any, client: .value("codex"), using: .any).willReturn(.success(installedDocument))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        let claudeRowBefore = sut.rows.first { $0.key == "claude-code" }
        let codexRow = sut.rows.first { $0.key == "codex" }!
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstall(codexRow) }
        dialog.actions.first?.action()
        
        // then
        await waitUntil { sut.rows.first { $0.key == "codex" }?.installed == true }
        #expect(sut.rows.first { $0.key == "codex" }?.installed == true)
        #expect(sut.rows.first { $0.key == "claude-code" } == claudeRowBefore)
        // The action runs the exact client `run` located — one lookup, as the original did.
        verify(useCase).locate().called(1)
        verify(useCase).perform(.any, client: .value("codex"), using: .matching { $0.executable == "/bin/polybridge-setup" }).called(1)
        withExtendedLifetime(cancellable) {}
    }
    
    @Test func givenAHarnessActionFails_whenCompleted_thenTheErrorMessageIsSetAndRowsAreUnchanged() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        let failure = ToolError.notFound(tool: "polybridge-setup", searched: ["/usr/local/bin"])
        given(useCase).perform(.any, client: .value("claude-code"), using: .any).willReturn(.failure(failure))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        let row = sut.rows.first { $0.key == "claude-code" }!
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()
        
        // then
        await waitUntil { sut.errorMessage != nil }
        #expect(sut.errorMessage == failure.message)
        #expect(sut.rows.count == 2)
        withExtendedLifetime(cancellable) {}
    }
    
    // Regression (item 8): the original's `run` located `polybridge-setup` BEFORE setting `working`
    // (`SettingsView.swift:134`) — a locator failure was a silent no-op, leaving both `working` and
    // `error` untouched. `load()`'s own locator failure is unaffected and still surfaces normally
    // (covered by `givenAppear_whenStatusFails_thenTheErrorMessageIsSet` above).
    @Test func givenTheLocatorFailsInRun_whenAnActionIsConfirmed_thenItIsASilentNoOp() async {
        // given — the status load itself succeeds (so rows exist to act on), but the separate
        // locate the original ran again inside `run` fails.
        let locateFailure = ToolError.notFound(tool: "polybridge-setup", searched: ["/usr/local/bin"])
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        given(useCase).locate().willReturn(.failure(locateFailure))
        given(useCase).perform(.any, client: .any, using: .any).willReturn(.failure(locateFailure))
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 }
        let row = sut.rows.first { $0.key == "claude-code" }!
        
        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()
        // `run` is `Task { ... }`-dispatched from the dialog action; wait for `locate()` to have
        // actually run (proving the Task itself ran) rather than a fixed sleep, before asserting the
        // silent no-op that should follow it.
        await verify(useCase).locate().calledEventually(1, before: .seconds(1))
        
        // then — neither `working` nor `error` moved, and the real `perform` (the action itself)
        // was never even attempted.
        #expect(sut.workingKey == nil)
        #expect(sut.errorMessage == nil)
        verify(useCase).perform(.any, client: .any, using: .any).called(0)
        withExtendedLifetime(cancellable) {}
    }
}
