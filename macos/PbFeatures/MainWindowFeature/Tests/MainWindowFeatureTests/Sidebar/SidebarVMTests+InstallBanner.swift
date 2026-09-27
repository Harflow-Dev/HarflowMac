import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import Testing

@MainActor
extension SidebarVMTests {

    // MARK: - Install banner (settled plan, section 5)

    /// `publishDialog` dispatches via `Task { @MainActor in ... }`, not synchronously — mirrors
    /// `HarnessesVMTests`' own helper.
    private func waitForDialog(_ sut: SidebarVM, publish: () -> Void) async -> (dialog: AlertContent, cancellable: AnyCancellable) {
        var published: AlertContent?
        let cancellable = sut.objectDidPublishViewEvent.publisher.sink { event in
            if case .dialog(let dialog) = event { published = dialog }
        }
        publish()
        await waitUntil { published != nil }
        return (published!, cancellable)
    }

    @Test func givenNeedsGit_whenPrimaryTapped_thenInstallIsCalledDirectlyWithNoDialog() async {
        // given
        let harness = makeSUT(installState: .needsGit)
        let sut = harness.sut
        let useCase = harness.useCase
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "git is needed to install polybridge")
        #expect(sut.installBannerModel?.primaryTitle == "Try again")

        // when
        sut.didTapInstallBannerPrimary()

        // then
        await verify(useCase).install().calledEventually(1, before: .seconds(1))
    }

    @Test func givenNeedsUv_whenPrimaryTapped_thenTheInstallUvDialogPublishes_andConfirmCallsInstallUvThenPolybridge() async {
        // given
        let harness = makeSUT(installState: .needsUv)
        let sut = harness.sut
        let useCase = harness.useCase
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.primaryTitle == "Install uv")

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }
        #expect(dialog.title == "Install uv?")
        dialog.actions.first?.action()

        // then
        await verify(useCase).installUvThenPolybridge().calledEventually(1, before: .seconds(1))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenFailed_whenPrimaryTapped_thenRetryIsCalledDirectlyWithNoDialog() async {
        // given
        let harness = makeSUT(installState: .failed(stage: .polybridge, message: "Installing polybridge failed."))
        let sut = harness.sut
        let useCase = harness.useCase
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.errorText == "Installing polybridge failed.")
        #expect(sut.installBannerModel?.canDismiss == true)

        // when
        sut.didTapInstallBannerPrimary()

        // then
        await verify(useCase).retry().calledEventually(1, before: .seconds(1))
    }

    @Test func givenUnresolved_whenPrimaryTapped_thenCheckAgainIsCalledDirectlyWithNoDialog() async {
        // given
        let harness = makeSUT(installState: .unresolved(stage: .polybridge))
        let sut = harness.sut
        let useCase = harness.useCase
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.primaryTitle == "Check again")
        #expect(sut.installBannerModel?.secondaryTitle == "Install anyway")

        // when
        sut.didTapInstallBannerPrimary()

        // then
        await verify(useCase).checkAgain().calledEventually(1, before: .seconds(1))
    }

    @Test func givenUnresolved_whenSecondaryTapped_thenTheInstallAnywayDialogPublishes_andConfirmCallsInstallAnyway() async {
        // given
        let harness = makeSUT(installState: .unresolved(stage: .polybridge))
        let sut = harness.sut
        let useCase = harness.useCase
        harness.installDestinationBox.value = "/Users/x/.local/bin"
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerSecondary() }
        #expect(dialog.title == "Install anyway?")
        #expect(dialog.description?.contains("Installs into /Users/x/.local/bin.") == true)
        dialog.actions.first?.action()

        // then
        await verify(useCase).installAnyway().calledEventually(1, before: .seconds(1))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenUnresolvedWithAnInstallAnywayBlockedMessage_whenShown_thenItOutranksTheLastCheckMessage() async {
        // given
        let harness = makeSUT(installState: .unresolved(stage: .uv))
        let sut = harness.sut
        let lastCheckMessageSubject = harness.lastCheckMessageSubject
        let installAnywayBlockedMessageSubject = harness.installAnywayBlockedMessageSubject
        sut.didAppear()
        lastCheckMessageSubject.send("The install may still be finishing.")
        await waitUntil { sut.installBannerModel?.errorText == "The install may still be finishing." }

        // when
        installAnywayBlockedMessageSubject.send("Install anyway is refused until an earlier install is confirmed stopped.")

        // then
        await waitUntil { sut.installBannerModel?.errorText == "Install anyway is refused until an earlier install is confirmed stopped." }
        #expect(sut.installBannerModel?.errorText == "Install anyway is refused until an earlier install is confirmed stopped.")
    }

    @Test func givenRunning_whenShown_thenIsBusyIsTrueAndThereIsNoPrimary() async {
        // given
        let harness = makeSUT(installState: .running(.polybridge))
        let sut = harness.sut
        sut.didAppear()

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.isBusy == true)
        #expect(sut.installBannerModel?.primaryTitle == nil)
        #expect(sut.installBannerModel?.detail == "Installing polybridge from GitHub. This can take a few minutes.")
    }

    @Test func givenAnIncompleteInstallNeed_whenPrimaryTapped_thenTheUpdateDialogPublishes_andConfirmCallsInstall() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        harness.installNeedBox.value = .incomplete
        harness.installDestinationBox.value = "/Users/x/.local/bin"
        sut.didAppear()
        hasListedSubject.send(true)
        listErrorSubject.send(.notFound(tool: "polybridge-setup", searched: []))
        tasksSubject.send([])
        await waitUntil { sut.installBannerModel?.primaryTitle == "Update polybridge" }

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }
        #expect(dialog.title == "Update polybridge?")
        #expect(dialog.description?.contains("Installs into /Users/x/.local/bin.") == true)
        dialog.actions.first?.action()

        // then
        await verify(useCase).install().calledEventually(1, before: .seconds(1))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenAStaleConfirm_whenTheStateChangedBeforeConfirming_thenInstallIsNotCalled() async {
        // given — the state changes (e.g. a running install started elsewhere) between the dialog
        // publishing and the person confirming it.
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        let installStateSubject = harness.installStateSubject
        harness.installNeedBox.value = .missing
        sut.didAppear()
        hasListedSubject.send(true)
        listErrorSubject.send(.notFound(tool: "polybridge-ctl", searched: []))
        tasksSubject.send([])
        await waitUntil { sut.installBannerModel?.primaryTitle == "Install polybridge" }
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }

        // when
        installStateSubject.send(.running(.git))
        await waitUntil { sut.installBannerModel?.isBusy == true }
        dialog.actions.first?.action()

        // then
        verify(useCase).install().called(0)
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenInstalled_whenShown_thenTheSuccessBannerHasTheFootnoteAndCanDismiss() async {
        // given
        let harness = makeSUT(installState: .installed)
        let sut = harness.sut
        sut.didAppear()

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "polybridge is installed")
        #expect(sut.installBannerModel?.footnote == "Next: register it with your agents in Settings → Harnesses.")
        #expect(sut.installBannerModel?.canDismiss == true)
        #expect(sut.installBannerModel?.primaryTitle == nil)
    }

    @Test func givenASuccessBannerWithNoTasks_whenDismissed_thenTheEmptyStateMessageAppears() async {
        // given — Code review round 1, finding 4: `emptyStateMessage` depends on `installBannerModel`
        // (Review round 1 item 3's precedence gates on it), so a banner change — here, dismissal —
        // must recompute it, not leave it stuck at whatever an earlier, unrelated recompute left.
        let harness = makeSUT(installState: .installed)
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        let installStateSubject = harness.installStateSubject
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        hasListedSubject.send(true)
        tasksSubject.send([])
        await waitUntil { sut.isConnected }
        #expect(sut.emptyStateMessage == nil, "the success banner still owns the space")

        // when — dismissing resets the install state to `.idle` (mirroring what
        // `InstallRepositoryImpl.reset()` really does), clearing the banner.
        sut.didTapInstallBannerDismiss()
        installStateSubject.send(.idle)

        // then
        await waitUntil { sut.emptyStateMessage != nil }
        #expect(sut.installBannerModel == nil)
        #expect(sut.emptyStateMessage == "No tasks yet. Tasks started through polybridge appear here.")
    }

    @Test func givenInstalledWithACurrentListError_whenShown_thenTheErrorOutranksTheSuccessBanner() async {
        // given — R2-2: completion requires the barrier refresh to succeed, and any current tool
        // error afterward always outranks the success banner.
        let harness = makeSUT(installState: .installed)
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        await waitUntil { sut.installBannerModel?.title == "polybridge is installed" }

        // when — a listing error that is not an install need arrives after completion.
        let error = ToolError.launchFailed(tool: "polybridge-ctl", detail: "crashed")
        hasListedSubject.send(true)
        listErrorSubject.send(error)
        tasksSubject.send([])

        // then
        await waitUntil { sut.listErrorMessage != nil }
        #expect(sut.listErrorMessage == error.message)
        #expect(sut.installBannerModel == nil)
    }

    @Test func givenDismissTapped_whenCalled_thenResetIsCalled() {
        // given
        let harness = makeSUT(installState: .installed)
        let sut = harness.sut
        let useCase = harness.useCase

        // when
        sut.didTapInstallBannerDismiss()

        // then
        verify(useCase).reset().called(1)
    }
}
