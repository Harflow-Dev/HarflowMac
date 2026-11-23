import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

@MainActor
extension MenuBarVMTests {

    // MARK: - Install banner

    @Test func givenDidDisappear_whenTheInstallStatePublishes_thenTheBannerStillUpdates() async {
        // given — the install-state subscription joins the core group (settled plan, section 5):
        // it must survive the popover closing exactly like `tasksPublisher`/etc.
        let harness = makeSUT()
        let sut = harness.sut
        let installStateSubject = harness.installStateSubject
        sut.didAppear()
        sut.didDisappear()

        // when
        installStateSubject.send(.failed(stage: .harflow, message: "fixture failure"))

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "Harflow runtime preparation failed")
    }

    @Test func givenFailed_whenPrimaryTapped_thenRetryIsCalled() async {
        // given
        let harness = makeSUT(installState: .failed(stage: .harflow, message: "fixture failure"))
        let sut = harness.sut
        let useCase = harness.useCase
        sut.didAppear()
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.primaryTitle == "Try again")
        #expect(sut.installBannerModel?.errorText == "fixture failure")

        // when
        sut.didTapInstallBannerPrimary()

        // then
        await verify(useCase).retry().calledEventually(1, before: .seconds(5))
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

    @Test func givenInstalled_whenShown_thenTheSuccessBannerHasTheFootnoteAndCanDismiss() async {
        // given
        let harness = makeSUT(installState: .installed)
        let sut = harness.sut
        sut.didAppear()

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.installBannerModel?.title == "harflow is installed")
        #expect(sut.installBannerModel?.footnote == "Next: register it with your harnesses in Settings → Harnesses.")
        #expect(sut.installBannerModel?.canDismiss == true)
    }

    @Test func givenInstalledWithACurrentListError_whenShown_thenTheErrorOutranksTheSuccessBanner() async {
        // given — R2-2: a current tool error always outranks the success banner.
        let harness = makeSUT(installState: .installed)
        let sut = harness.sut
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        await waitUntil { sut.installBannerModel?.title == "harflow is installed" }

        // when
        let error = ToolError.launchFailed(tool: "harflow-ctl", detail: "crashed")
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
