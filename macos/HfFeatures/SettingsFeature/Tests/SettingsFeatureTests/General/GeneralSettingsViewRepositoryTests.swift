import Combine
import Foundation
import HfRepository
import Mockable
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct GeneralSettingsViewRepositoryTests {
    
    private func makeSUT(
        settings: MockSettingsRepository = MockSettingsRepository(),
        taskList: MockTaskListRepository = MockTaskListRepository(),
        install: MockInstallRepository = MockInstallRepository()
    ) -> GeneralSettingsViewRepository {
        GeneralSettingsViewRepository(settingsRepository: settings, taskListRepository: taskList, installRepository: install)
    }

    @Test func givenTheRepositoryProperties_whenRead_thenTheyPassThroughToSettingsRepository() {
        // given
        let settings = MockSettingsRepository()
        given(settings).openWindowOnStart.willReturn(false)
        given(settings).notifyOnFinish.willReturn(false)
        given(settings).notifyOnNeedsYou.willReturn(false)
        given(settings).appAppearance.willReturn(.dark)
        let sut = makeSUT(settings: settings)

        // then
        #expect(sut.appAppearance == .dark)
        #expect(sut.openWindowOnStart == false)
        #expect(sut.notifyOnFinish == false)
        #expect(sut.notifyOnNeedsYou == false)
    }

    @Test func givenTheSetters_whenCalled_thenTheyPassThroughToSettingsRepository() {
        // given
        let settings = MockSettingsRepository()
        given(settings).setOpenWindowOnStart(.any).willReturn()
        given(settings).setNotifyOnFinish(.any).willReturn()
        given(settings).setNotifyOnNeedsYou(.any).willReturn()
        given(settings).setAppAppearance(.any).willReturn()
        let sut = makeSUT(settings: settings)

        // when
        sut.setOpenWindowOnStart(false)
        sut.setNotifyOnFinish(false)
        sut.setNotifyOnNeedsYou(false)
        sut.setAppAppearance(.light)

        // then
        verify(settings).setAppAppearance(.value(.light)).called(1)
        verify(settings).setOpenWindowOnStart(.value(false)).called(1)
        verify(settings).setNotifyOnFinish(.value(false)).called(1)
        verify(settings).setNotifyOnNeedsYou(.value(false)).called(1)
    }
}
