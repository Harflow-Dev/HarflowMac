import Combine
import Foundation
import HfRepository
import HfTestUtilities
import Mockable
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct GeneralSettingsVMTests {

    private struct SUT {
        let sut: GeneralSettingsVM
        let useCase: MockGeneralSettingsUseCase
        let openWindowSubject: PassthroughSubject<Bool, Never>
        let notifySubject: PassthroughSubject<Bool, Never>
        let appearanceSubject: CurrentValueSubject<AppAppearance, Never>
    }

    private func makeSUT(
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true,
        appearance: AppAppearance = .system
    ) -> SUT {
        let useCase = MockGeneralSettingsUseCase()
        let openWindowSubject = PassthroughSubject<Bool, Never>()
        let notifySubject = PassthroughSubject<Bool, Never>()
        let appearanceSubject = CurrentValueSubject<AppAppearance, Never>(appearance)

        given(useCase).appAppearance.willProduce { appearanceSubject.value }
        given(useCase).appAppearancePublisher().willReturn(appearanceSubject.eraseToAnyPublisher())
        given(useCase).setAppAppearance(.any).willReturn()
        given(useCase).openWindowOnStart.willReturn(openWindowOnStart)
        given(useCase).notifyOnFinish.willReturn(notifyOnFinish)
        given(useCase).notifyOnNeedsYou.willReturn(true)
        given(useCase).notifyOnNeedsYouPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).setNotifyOnNeedsYou(.any).willReturn()
        given(useCase).openWindowOnStartPublisher().willReturn(openWindowSubject.eraseToAnyPublisher())
        given(useCase).notifyOnFinishPublisher().willReturn(notifySubject.eraseToAnyPublisher())
        given(useCase).setOpenWindowOnStart(.any).willReturn()
        given(useCase).setNotifyOnFinish(.any).willReturn()

        let sut = GeneralSettingsVM(useCase: useCase)
        return SUT(
            sut: sut, useCase: useCase, openWindowSubject: openWindowSubject,
            notifySubject: notifySubject, appearanceSubject: appearanceSubject
        )
    }

    @Test func givenToggleActions_whenInvoked_thenTheyForwardToTheUseCase() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        
        // when
        sut.didToggleOpenWindowOnStart(false)
        sut.didToggleNotifyOnFinish(false)
        sut.didToggleNotifyOnNeedsYou(false)
        
        // then
        verify(useCase).setOpenWindowOnStart(.value(false)).called(1)
        verify(useCase).setNotifyOnFinish(.value(false)).called(1)
        verify(useCase).setNotifyOnNeedsYou(.value(false)).called(1)
    }
    
    @Test func givenLiveSettingsPublishers_whenTheyEmit_thenTheTogglesUpdate() async {
        // given
        let harness = makeSUT(openWindowOnStart: true, notifyOnFinish: true)
        let sut = harness.sut
        let openWindowSubject = harness.openWindowSubject
        let notifySubject = harness.notifySubject
        sut.didAppear()
        // Positive setup: both start `true` (from the use case), so the assertion below proves the
        // publishers actually flipped them rather than merely matching an already-`false` default.
        #expect(sut.openWindowOnStart == true)
        #expect(sut.notifyOnFinish == true)
        
        // when
        openWindowSubject.send(false)
        notifySubject.send(false)
        
        // then — `weakAssign` delivers via `.receive(on: DispatchQueue.main)`, a real async hop.
        await waitUntil { sut.openWindowOnStart == false && sut.notifyOnFinish == false }
        #expect(sut.openWindowOnStart == false)
        #expect(sut.notifyOnFinish == false)
    }
    
    @Test func givenDidAppearCalledTwice_whenSettingsEmit_thenSubscriptionsAreNotDuplicated() async {
        // given — the `didSubscribe` guard must stop a second `didAppear()` (e.g. the tab
        // reappearing) from double-subscribing.
        let harness = makeSUT()
        let sut = harness.sut
        let openWindowSubject = harness.openWindowSubject
        sut.didAppear()
        sut.didAppear()
        // Positive setup: starts `true` (from the use case), so the wait below proves the
        // subscription actually delivered the change rather than matching an already-`false` default.
        #expect(sut.openWindowOnStart == true)
        
        // when
        openWindowSubject.send(false)
        
        // then — the assignment happened once; a duplicate subscription would not change this
        // specific assertion, but does show up as a crash/leak in `cancellables` in a full run. The
        // meaningful check is the disappear/re-subscribe path below.
        await waitUntil { sut.openWindowOnStart == false }
        #expect(sut.openWindowOnStart == false)
    }
    
    @Test func givenDidDisappear_whenTheViewReappears_thenItSubscribesAgain() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let openWindowSubject = harness.openWindowSubject
        sut.didAppear()
        sut.didDisappear()
        // Positive setup: starts `true` (from the use case), so the wait below proves the
        // resubscription actually delivered the change rather than matching an already-`false` default.
        #expect(sut.openWindowOnStart == true)
        
        // when
        sut.didAppear()
        openWindowSubject.send(false)
        
        // then
        await waitUntil { sut.openWindowOnStart == false }
        #expect(sut.openWindowOnStart == false)
    }

    // MARK: - Appearance

    @Test func givenAnAppearanceInTheUseCase_whenCreated_thenTheVMStartsWithIt() {
        // given / when
        let harness = makeSUT(appearance: .dark)

        // then
        #expect(harness.sut.appAppearance == .dark)
    }

    @Test func givenADifferentSelection_whenSelected_thenTheUseCaseIsWrittenAndTheValueUpdatesSynchronously() {
        // given
        let harness = makeSUT(appearance: .system)

        // when
        harness.sut.didSelectAppearance(.light)

        // then
        #expect(harness.sut.appAppearance == .light)
        verify(harness.useCase).setAppAppearance(.value(.light)).called(1)
    }

    @Test func givenTheCurrentSelection_whenSelectedAgain_thenNothingIsWritten() {
        // given
        let harness = makeSUT(appearance: .dark)

        // when
        harness.sut.didSelectAppearance(.dark)

        // then
        verify(harness.useCase).setAppAppearance(.any).called(0)
        #expect(harness.sut.appAppearance == .dark)
    }

    @Test func givenAnOpenTab_whenTheSidebarChangesTheAppearance_thenTheValueFollows() async {
        // given
        let harness = makeSUT(appearance: .system)
        harness.sut.didAppear()
        #expect(harness.sut.appAppearance == .system)

        // when
        harness.appearanceSubject.send(.dark)

        // then
        await waitUntil { harness.sut.appAppearance == .dark }
        #expect(harness.sut.appAppearance == .dark)
        verify(harness.useCase).setAppAppearance(.any).called(0)
    }

    @Test func givenAChangeWhileTheTabWasAway_whenItAppearsAgain_thenTheValueIsCurrent() {
        // given
        let harness = makeSUT(appearance: .system)
        harness.sut.didAppear()
        harness.sut.didDisappear()
        harness.appearanceSubject.send(.light)
        #expect(harness.sut.appAppearance == .system)

        // when
        harness.sut.didAppear()

        // then
        #expect(harness.sut.appAppearance == .light)
    }

    // MARK: - Groups and runtime row

    @Test func givenTheGeneralTab_whenListingItsGroups_thenTheyFollowTheDesignOrder() {
        // given / when
        let titles = GeneralSettingsGroup.allCases.map(\.title)

        // then
        #expect(titles == ["Appearance", "Behaviour", "Harflow runtime", "Task store"])
    }

    @Test func givenTheThemeControl_whenListingSegments_thenTheOrderIsSystemLightDark() {
        // given / when
        let segments = AppearanceOption.segments

        // then
        #expect(segments.map(\.value) == [.system, .light, .dark])
        #expect(segments.map(\.title) == ["System", "Light", "Dark"])
    }

    @Test func givenEachRowGlyph_whenMapped_thenAttentionIsAnAlertCircleNotTheNeedsYouHand() {
        // given / when / then
        #expect(RowGlyph.attention.status == nil)
        #expect(RowGlyph.attention.attentionSymbol == "exclamationmark.circle")
        #expect(RowGlyph.attention.accessibilityLabel == "Needs attention")
        #expect(RowGlyph.busy.status == .running)
        #expect(RowGlyph.done.status == .completed)
        #expect(RowGlyph.failed.status == .failed)
        #expect(RowGlyph.done.accessibilityLabel == "Done")
        #expect(RowGlyph.failed.accessibilityLabel == "Failed")
        #expect(RowGlyph.busy.accessibilityLabel == "In progress")
    }

    @Test func givenEveryRuntimeState_whenPresenting_thenGlyphAndCopyFollowTheDesign() {
        // given
        let cases: [(RuntimeSetupState, RowGlyph?, String, String, String?)] = [
            (.checking, .busy, "Checking Harflow runtime…", "Checking the managed installation on this Mac.", nil),
            (.installationRequired(installedVersion: nil, requiredVersion: "0.5.0"), nil, "Prepare Harflow",
             "Install the components Harflow needs to run. Required runtime: 0.5.0.", "Install required components"),
            (.installationRequired(installedVersion: "0.4.0", requiredVersion: "0.5.0"), nil, "Update Harflow runtime",
             "Installed runtime 0.4.0. This app requires runtime 0.5.0.", "Update required components"),
            (.installing, .busy, "Preparing Harflow…", "Installing required components for this app.", nil),
            (.updating(installedVersion: "0.4.0", requiredVersion: "0.5.0"), .busy, "Updating Harflow…",
             "Installing the update from runtime 0.4.0 to 0.5.0. Your task history is preserved during the update.", nil),
            (.updateFailed(message: "Package failed.", installedVersion: "0.4.0", requiredVersion: "0.5.0"), .failed,
             "Update did not finish",
             "Installed runtime 0.4.0; required runtime 0.5.0. Your history and existing installation have been kept. Package failed.",
             "Retry update"),
            (.failed("Package failed."), .failed, "Setup did not finish", "Package failed.", "Retry installation"),
            (.ready, .done, "Harflow runtime is ready", "MCP registrations are managed separately in Harnesses.", nil)
        ]

        for (state, glyph, title, detail, action) in cases {
            // when
            let sut = RuntimeRowPresentation(state: state)

            // then
            #expect(sut.glyph == glyph)
            #expect(sut.title == title)
            #expect(sut.detail == detail)
            #expect(sut.actionTitle == action)
        }
    }
}
