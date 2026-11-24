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
        install: MockInstallRepository = MockInstallRepository(),
        notifier: (any NeedsYouNotifier)? = nil
    ) -> GeneralSettingsViewRepository {
        GeneralSettingsViewRepository(
            settingsRepository: settings, taskListRepository: taskList, installRepository: install, needsYouNotifier: notifier
        )
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

    @Test func givenTheNotifier_whenReadingPermissionAndFeed_thenTheyPassThrough() async {
        // given
        let notifier = MockNeedsYouNotifier()
        let feed = CurrentValueSubject<NotificationFeedAvailability, Never>(.available)
        given(notifier).permission().willReturn(.denied)
        given(notifier).feedAvailability.willReturn(.available)
        given(notifier).feedAvailabilityPublisher().willReturn(feed.eraseToAnyPublisher())
        let sut = makeSUT(notifier: notifier)
        var received: [NotificationFeedAvailability] = []
        let cancellable = sut.feedAvailabilityPublisher().sink { received.append($0) }
        defer { cancellable.cancel() }

        // when
        feed.send(.unavailable)
        let permission = await sut.notificationPermission()

        // then
        #expect(permission == .denied)
        #expect(sut.feedAvailability == .available)
        #expect(received == [.available, .unavailable])
    }

    @Test func givenTheDefaultNotifier_whenReadingPermission_thenThereIsNone() async {
        // given
        let sut = makeSUT()

        // when
        let permission = await sut.notificationPermission()

        // then
        #expect(permission == nil)
        #expect(sut.feedAvailability == .unknown)
    }
}
