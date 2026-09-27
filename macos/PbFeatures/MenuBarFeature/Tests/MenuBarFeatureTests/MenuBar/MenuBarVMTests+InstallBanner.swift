import Combine
import Foundation
@testable import MenuBarFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import Testing

@MainActor
extension MenuBarVMTests {

    // MARK: - Install banner (settled plan, section 5)

    @Test func givenDidDisappear_whenTheInstallStatePublishes_thenTheBannerStillUpdates() async {
        // given — the install-state subscription joins the core group (settled plan, section 5):
        // it must survive the popover closing exactly like `tasksPublisher`/etc.
        let harness = makeSUT()
        let sut = harness.sut
        let installStateSubject = harness.installStateSubject
        sut.didAppear()
        sut.didDisappear()

        // when
        installStateSubject.send(.needsGit)

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "git is needed to install polybridge")
    }

    // MARK: - Install banner (settled plan, section 5)

    /// `publishDialog` dispatches via `Task { @MainActor in ... }`, not synchronously.
    private func waitForDialog(_ sut: MenuBarVM, publish: () -> Void) async -> (dialog: AlertContent, cancellable: AnyCancellable) {
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

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }
        #expect(dialog.title == "Install uv?")
        dialog.actions.first?.action()

        // then
        await verify(useCase).installUvThenPolybridge().calledEventually(1, before: .seconds(1))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenUnresolved_whenSecondaryTapped_thenTheInstallAnywayDialogPublishes_andConfirmCallsInstallAnyway() async {
        // given
        let harness = makeSUT(installState: .unresolved(stage: .polybridge))
        let sut = harness.sut
        let useCase = harness.useCase
        harness.installDestinationBox.value = "/Users/x/.local/bin"
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.primaryTitle == "Check again")
        #expect(sut.installBannerModel?.secondaryTitle == "Install anyway")

        // when
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerSecondary() }
        #expect(dialog.title == "Install anyway?")
        #expect(dialog.description?.contains("Installs into /Users/x/.local/bin.") == true)
        dialog.actions.first?.action()

        // then
        await verify(useCase).installAnyway().calledEventually(1, before: .seconds(1))
        withExtendedLifetime(cancellable) {}
    }

    @Test func givenRunning_whenShown_thenIsBusyIsTrueAndThereIsNoPrimary() async {
        // given
        let harness = makeSUT(installState: .running(.validate))
        let sut = harness.sut
        sut.didAppear()

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.isBusy == true)
        #expect(sut.installBannerModel?.primaryTitle == nil)
        #expect(sut.installBannerModel?.title == "Checking…")
    }

    @Test func givenAStaleConfirm_whenTheStateChangedBeforeConfirming_thenInstallUvThenPolybridgeIsNotCalled() async {
        // given — the state changes between the dialog publishing and the person confirming it.
        let harness = makeSUT(installState: .needsUv)
        let sut = harness.sut
        let useCase = harness.useCase
        let installStateSubject = harness.installStateSubject
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        let (dialog, cancellable) = await waitForDialog(sut) { sut.didTapInstallBannerPrimary() }

        // when — an install elsewhere completed the uv stage before this dialog was confirmed.
        installStateSubject.send(.running(.polybridge))
        await waitUntil { sut.installBannerModel?.isBusy == true }
        dialog.actions.first?.action()

        // then
        verify(useCase).installUvThenPolybridge().called(0)
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
    }

    @Test func givenInstalledWithACurrentListError_whenShown_thenTheErrorOutranksTheSuccessBanner() async {
        // given — R2-2: a current tool error that isn't an install need always outranks the success
        // banner.
        let harness = makeSUT(installState: .installed)
        let sut = harness.sut
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        await waitUntil { sut.installBannerModel?.title == "polybridge is installed" }

        // when
        let error = ToolError.launchFailed(tool: "polybridge-ctl", detail: "crashed")
        hasListedSubject.send(true)
        listErrorSubject.send(error)

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
