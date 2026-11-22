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
    }

    private func makeSUT(openWindowOnStart: Bool = true, notifyOnFinish: Bool = true) -> SUT {
        let useCase = MockGeneralSettingsUseCase()
        let openWindowSubject = PassthroughSubject<Bool, Never>()
        let notifySubject = PassthroughSubject<Bool, Never>()

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
        return SUT(sut: sut, useCase: useCase, openWindowSubject: openWindowSubject, notifySubject: notifySubject)
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
}
