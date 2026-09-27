import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
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
        locate: Result<SetupClient, ToolError> = .success(HarnessesVMTests.setupClient),
        installState: InstallState = .idle,
        installNeed: @escaping (ToolError) -> InstallNeed? = { _ in nil }
    ) -> (sut: HarnessesVM, useCase: MockHarnessesUseCase) {
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(status)
        given(useCase).locate().willReturn(locate)
        Self.stubInstall(useCase, installState: installState, installNeed: installNeed)
        let sut = HarnessesVM(useCase: useCase)
        return (sut, useCase)
    }

    /// Every `HarnessesVM` construction reads `installState`/`lastCheckMessage`/
    /// `installAnywayBlockedMessage` in `init`, and `didAppear()` subscribes to their publishers —
    /// so any test building its own `MockHarnessesUseCase` (bypassing `makeSUT`) needs these
    /// defaults too, or Mockable fatals on the unstubbed member.
    private static func stubInstall(
        _ useCase: MockHarnessesUseCase,
        installState: InstallState = .idle,
        installStatePublisher: AnyPublisher<InstallState, Never>? = nil,
        lastCheckMessagePublisher: AnyPublisher<String?, Never>? = nil,
        installAnywayBlockedMessagePublisher: AnyPublisher<String?, Never>? = nil,
        installNeed: @escaping (ToolError) -> InstallNeed? = { _ in nil }
    ) {
        given(useCase).installState.willReturn(installState)
        given(useCase).installStatePublisher().willReturn(installStatePublisher ?? Empty().eraseToAnyPublisher())
        given(useCase).lastCheckMessage.willReturn(nil)
        given(useCase).lastCheckMessagePublisher().willReturn(lastCheckMessagePublisher ?? Empty().eraseToAnyPublisher())
        given(useCase).installAnywayBlockedMessage.willReturn(nil)
        given(useCase).installAnywayBlockedMessagePublisher().willReturn(installAnywayBlockedMessagePublisher ?? Empty().eraseToAnyPublisher())
        given(useCase).installNeed(for: .any).willProduce(installNeed)
        given(useCase).installDestination().willReturn(nil)
        given(useCase).install().willReturn()
        given(useCase).installUvThenPolybridge().willReturn()
        given(useCase).retry().willReturn()
        given(useCase).checkAgain().willReturn()
        given(useCase).installAnyway().willReturn(true)
        given(useCase).reset().willReturn()
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
    
    @Test func givenAppear_whenStatusFailsWithANonInstallNeed_thenTheErrorMessageIsSet() async {
        // given
        let failure = ToolError.refused(code: "denied", message: "polybridge-setup refused the request.")
        let (sut, _) = makeSUT(status: .failure(failure))

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.errorMessage != nil }
        #expect(sut.errorMessage == failure.message)
        #expect(sut.rows.isEmpty)
        #expect(sut.installBannerModel == nil)
    }

    // Moved from a `.message`-forwarding assertion (settled plan, section 7): a `notFound` error
    // for `polybridge-ctl`/`polybridge-setup` is an install need, so it now shows the banner instead
    // of the plain red `errorMessage`.
    @Test func givenAppear_whenStatusFailsWithAnInstallNeed_thenTheBannerShowsInsteadOfTheRedText() async {
        // given
        let failure = ToolError.notFound(tool: "polybridge-setup", searched: ["/usr/local/bin"])
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(.failure(failure))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubInstall(useCase, installNeed: { $0 == failure ? .incomplete : nil })
        let sut = HarnessesVM(useCase: useCase)

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.errorMessage == nil)
        #expect(sut.rows.isEmpty)
        #expect(sut.installBannerModel?.title == "polybridge is incomplete or out of date")
        #expect(sut.installBannerModel?.detail == failure.message)
        #expect(sut.installBannerModel?.primaryTitle == "Update polybridge")
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
        Self.stubInstall(useCase)
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
        Self.stubInstall(useCase)
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
    
    @Test func givenInstalled_whenAHarnessActionFails_thenTheErrorOutranksTheSuccessBanner() async {
        // given — the success banner is showing after an install.
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(.success(document(twoRowsJSON)))
        let failure = ToolError.launchFailed(tool: "polybridge-setup", detail: "crashed")
        given(useCase).perform(.any, client: .value("claude-code"), using: .any).willReturn(.failure(failure))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubInstall(useCase, installState: .installed)
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.rows.count == 2 && sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "polybridge is installed")
        let row = sut.rows.first { $0.key == "claude-code" }!

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapRemove(row) }
        dialog.actions.first?.action()

        // then
        await waitUntil { sut.errorMessage != nil }
        #expect(sut.errorMessage == failure.message)
        #expect(sut.installBannerModel == nil)
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
        Self.stubInstall(useCase)
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
        await verify(useCase).locate().calledEventually(1, before: .seconds(5))
        
        // then — neither `working` nor `error` moved, and the real `perform` (the action itself)
        // was never even attempted.
        #expect(sut.workingKey == nil)
        #expect(sut.errorMessage == nil)
        verify(useCase).perform(.any, client: .any, using: .any).called(0)
        withExtendedLifetime(cancellable) {}
    }

    // MARK: - Install banner (settled plan, section 5)

    @Test func givenNeedsGit_whenPrimaryTapped_thenInstallIsCalledDirectlyWithNoDialog() async {
        // given
        let (sut, useCase) = makeSUT(installState: .needsGit)
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "git is needed to install polybridge")
        #expect(sut.installBannerModel?.primaryTitle == "Try again")

        // when
        sut.didTapInstallBannerPrimary()

        // then
        await verify(useCase).install().calledEventually(1, before: .seconds(5))
    }

    @Test func givenNeedsUv_whenPrimaryTapped_thenTheInstallUvDialogPublishes_andConfirmCallsInstallUvThenPolybridge() async {
        // given
        let (sut, useCase) = makeSUT(installState: .needsUv)
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }
        #expect(dialog.title == "Install uv?")
        dialog.actions.first?.action()

        // then
        await verify(useCase).installUvThenPolybridge().calledEventually(1, before: .seconds(5))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenFailed_whenPrimaryTapped_thenRetryIsCalledDirectlyWithNoDialog() async {
        // given
        let (sut, useCase) = makeSUT(installState: .failed(stage: .polybridge, message: "Installing polybridge failed."))
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.errorText == "Installing polybridge failed.")
        #expect(sut.installBannerModel?.canDismiss == true)

        // when
        sut.didTapInstallBannerPrimary()

        // then
        await verify(useCase).retry().calledEventually(1, before: .seconds(5))
    }

    @Test func givenUnresolved_whenPrimaryTapped_thenCheckAgainIsCalledDirectlyWithNoDialog() async {
        // given
        let (sut, useCase) = makeSUT(installState: .unresolved(stage: .polybridge))
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.primaryTitle == "Check again")
        #expect(sut.installBannerModel?.secondaryTitle == "Install anyway")

        // when
        sut.didTapInstallBannerPrimary()

        // then
        await verify(useCase).checkAgain().calledEventually(1, before: .seconds(5))
    }

    @Test func givenUnresolved_whenSecondaryTapped_thenTheInstallAnywayDialogPublishes_andConfirmCallsInstallAnyway() async {
        // given
        let (sut, useCase) = makeSUT(installState: .unresolved(stage: .polybridge))
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerSecondary() }
        #expect(dialog.title == "Install anyway?")
        dialog.actions.first?.action()

        // then
        await verify(useCase).installAnyway().calledEventually(1, before: .seconds(5))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenAnIncompleteInstallNeed_whenPrimaryTapped_thenTheUpdateDialogPublishes_andConfirmCallsInstall() async {
        // given
        let failure = ToolError.notFound(tool: "polybridge-setup", searched: [])
        let (sut, useCase) = makeSUT(status: .failure(failure), installNeed: { $0 == failure ? .incomplete : nil })
        sut.didAppear()
        await waitUntil { sut.installBannerModel?.primaryTitle == "Update polybridge" }

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }
        #expect(dialog.title == "Update polybridge?")
        dialog.actions.first?.action()

        // then
        await verify(useCase).install().calledEventually(1, before: .seconds(5))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenRunning_whenShown_thenIsBusyIsTrueAndThereIsNoPrimary() async {
        // given
        let (sut, _) = makeSUT(installState: .running(.polybridge))
        sut.didAppear()

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.isBusy == true)
        #expect(sut.installBannerModel?.primaryTitle == nil)
        #expect(sut.installBannerModel?.detail == "Installing polybridge from GitHub. This can take a few minutes.")
    }

    @Test func givenAStaleConfirm_whenTheStateChangedBeforeConfirming_thenInstallUvThenPolybridgeIsNotCalled() async {
        // given — the state changes between the dialog publishing and the person confirming it.
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(.success(document(HarnessesVMTests.emptyDocumentJSON)))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        let installStateSubject = PassthroughSubject<InstallState, Never>()
        Self.stubInstall(useCase, installState: .needsUv, installStatePublisher: installStateSubject.eraseToAnyPublisher())
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }

        // when — an install started elsewhere already moved past `needsUv` before this dialog was confirmed.
        installStateSubject.send(.running(.uv))
        await waitUntil { sut.installBannerModel?.isBusy == true }
        dialog.actions.first?.action()

        // then
        verify(useCase).installUvThenPolybridge().called(0)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenUnresolvedWithAnInstallAnywayBlockedMessage_whenShown_thenItOutranksTheLastCheckMessage() async {
        // given
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willReturn(.success(document(HarnessesVMTests.emptyDocumentJSON)))
        given(useCase).locate().willReturn(.success(Self.setupClient))
        let lastCheckMessageSubject = PassthroughSubject<String?, Never>()
        let installAnywayBlockedMessageSubject = PassthroughSubject<String?, Never>()
        Self.stubInstall(
            useCase, installState: .unresolved(stage: .uv),
            lastCheckMessagePublisher: lastCheckMessageSubject.eraseToAnyPublisher(),
            installAnywayBlockedMessagePublisher: installAnywayBlockedMessageSubject.eraseToAnyPublisher()
        )
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        lastCheckMessageSubject.send("The install may still be finishing.")
        await waitUntil { sut.installBannerModel?.errorText == "The install may still be finishing." }

        // when
        installAnywayBlockedMessageSubject.send("Install anyway is refused until an earlier install is confirmed stopped.")

        // then
        await waitUntil { sut.installBannerModel?.errorText == "Install anyway is refused until an earlier install is confirmed stopped." }
        #expect(sut.installBannerModel?.errorText == "Install anyway is refused until an earlier install is confirmed stopped.")
    }

    @Test func givenInstalled_whenShown_thenTheSuccessBannerHasTheFootnoteAndCanDismiss() async {
        // given
        let (sut, _) = makeSUT(installState: .installed)
        sut.didAppear()

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "polybridge is installed")
        #expect(sut.installBannerModel?.footnote == "Next: register it with your agents in Settings → Harnesses.")
        #expect(sut.installBannerModel?.canDismiss == true)
        #expect(sut.installBannerModel?.primaryTitle == nil)
    }

    @Test func givenInstalledWithACurrentLoadError_whenShown_thenTheErrorOutranksTheSuccessBanner() async {
        // given — R2-2: a current tool error that isn't an install need always outranks the success
        // banner. The load error is set by a `load()` that ran before installation completed.
        let failure = ToolError.launchFailed(tool: "polybridge-setup", detail: "crashed")
        let (sut, _) = makeSUT(status: .failure(failure), installState: .installed)

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.errorMessage != nil }
        #expect(sut.errorMessage == failure.message)
        #expect(sut.installBannerModel == nil)
    }

    @Test func givenDismissTapped_whenCalled_thenResetIsCalled() {
        // given
        let (sut, useCase) = makeSUT(installState: .installed)

        // when
        sut.didTapInstallBannerDismiss()

        // then
        verify(useCase).reset().called(1)
    }

    // MARK: - Generation guard and reload after install (settled plan, section 5)

    @Test func givenTheGenerationAdvancesMidFlight_whenTheOlderCallResolves_thenItsResultIsDropped() async {
        // given — Mockable's generated `willProduce` for an `async` member only takes a
        // *synchronous* producer (no suspending overload — see `FunctionReturnBuilder`), so two
        // genuinely-overlapping `load()` calls can't be raced directly. So instead the producer bumps
        // `sut.loadGeneration` itself, mid-call, simulating "a newer load already started" while
        // this one is still awaiting its own answer — exactly the race the guard exists to close.
        // `loadGeneration` is `internal`, not `private`: this test technique needs to reach it from
        // outside the file.
        final class SUTBox { var sut: HarnessesVM? }
        let sutBox = SUTBox()
        let staleDocumentJSON = #"{"v":1,"clients":[{"key":"claude-code","available":true,"installed":true,"current":true}]}"#
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willProduce {
            sutBox.sut?.loadGeneration += 1
            return .success(Self.document(staleDocumentJSON))
        }
        given(useCase).locate().willReturn(.success(Self.setupClient))
        Self.stubInstall(useCase)
        let sut = HarnessesVM(useCase: useCase)
        sutBox.sut = sut
        
        // when
        sut.didAppear()
        
        // then — the completion belongs to a generation that is already stale by the time it
        // resolves, so it must be dropped entirely: rows never populate, and `isLoading` — the
        // cleanup that used to be an unconditional `defer` — never clears either.
        await verify(useCase).status().calledEventually(1, before: .seconds(5))
        #expect(sut.rows.isEmpty)
        #expect(sut.isLoading == true)
    }

    @Test func givenTheStateBecomesInstalled_whenObserved_thenHarnessesReloads() async {
        // given
        final class StatusBox {
            var value: Result<SetupDocument, ToolError>
            init(_ value: Result<SetupDocument, ToolError>) { self.value = value }
        }
        let statusBox = StatusBox(.success(document(HarnessesVMTests.emptyDocumentJSON)))
        let useCase = MockHarnessesUseCase()
        given(useCase).status().willProduce { statusBox.value }
        given(useCase).locate().willReturn(.success(Self.setupClient))
        let installStateSubject = PassthroughSubject<InstallState, Never>()
        Self.stubInstall(useCase, installStatePublisher: installStateSubject.eraseToAnyPublisher())
        let sut = HarnessesVM(useCase: useCase)
        sut.didAppear()
        // The initial load must have completed first, or it alone could fetch the two rows below.
        await verify(useCase).status().calledEventually(1, before: .seconds(5))
        await waitUntil { sut.isLoading == false }
        #expect(sut.rows.isEmpty)
        statusBox.value = .success(document(twoRowsJSON))

        // when
        installStateSubject.send(.installed)

        // then
        await verify(useCase).status().calledEventually(2, before: .seconds(5))
        await waitUntil { sut.rows.count == 2 }
        #expect(sut.rows.count == 2)
        #expect(sut.installBannerModel?.title == "polybridge is installed")
    }
}
