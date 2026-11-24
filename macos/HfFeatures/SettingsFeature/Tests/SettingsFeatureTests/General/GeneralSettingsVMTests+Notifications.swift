import Combine
import Foundation
import HfRepository
import HfTestUtilities
import Mockable
@testable import SettingsFeature
import Testing

// MARK: - GeneralSettingsVMTests notification row

extension GeneralSettingsVMTests {
    /// A use case that also reports the notification permission, which `MockGeneralSettingsUseCase` cannot do.
    @MainActor
    private final class NotifyingUseCase: GeneralSettingsUseCase, NotificationPermissionObserving, @unchecked Sendable {
        var permission: NotificationAuthorization?
        private(set) var permissionReads = 0
        var feedAvailability: NotificationFeedAvailability
        let feedSubject: CurrentValueSubject<NotificationFeedAvailability, Never>
        let activationSubject = PassthroughSubject<Void, Never>()

        var openWindowOnStart = true
        var notifyOnFinish = true
        var notifyOnNeedsYou = true
        var appAppearance = AppAppearance.system

        init(permission: NotificationAuthorization?, feed: NotificationFeedAvailability = .unknown) {
            self.permission = permission
            self.feedAvailability = feed
            self.feedSubject = CurrentValueSubject(feed)
        }

        func notificationPermission() async -> NotificationAuthorization? {
            permissionReads += 1
            return permission
        }

        func feedAvailabilityPublisher() -> AnyPublisher<NotificationFeedAvailability, Never> { feedSubject.eraseToAnyPublisher() }
        func activationPublisher() -> AnyPublisher<Void, Never> { activationSubject.eraseToAnyPublisher() }

        func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { Just(openWindowOnStart).eraseToAnyPublisher() }
        func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { Just(notifyOnFinish).eraseToAnyPublisher() }
        func notifyOnNeedsYouPublisher() -> AnyPublisher<Bool, Never> { Just(notifyOnNeedsYou).eraseToAnyPublisher() }
        func appAppearancePublisher() -> AnyPublisher<AppAppearance, Never> { Just(appAppearance).eraseToAnyPublisher() }
        func setOpenWindowOnStart(_: Bool) {}
        func setNotifyOnFinish(_: Bool) {}
        func setNotifyOnNeedsYou(_: Bool) {}
        func setAppAppearance(_: AppAppearance) {}
    }

    @Test func givenDenied_whenAppearing_thenSwitchesDisabledAndButtonShown() async {
        // given
        let sut = GeneralSettingsVM(useCase: NotifyingUseCase(permission: .denied))
        #expect(sut.notificationRow == nil)

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.notificationRow != nil }
        #expect(sut.notificationRow?.state == .denied)
        #expect(sut.notificationRow?.actionTitle == "Open System Settings")
        #expect(sut.notificationSwitchesEnabled == false)
    }

    @Test func givenActivation_whenPermissionChanged_thenRowUpdates() async {
        // given
        let useCase = NotifyingUseCase(permission: .denied)
        let sut = GeneralSettingsVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.notificationRow?.state == .denied }

        // when
        useCase.permission = .allowed
        useCase.activationSubject.send()

        // then
        await waitUntil { sut.notificationRow?.state == .allowed }
        #expect(sut.notificationRow?.actionTitle == nil)
        #expect(sut.notificationSwitchesEnabled)
    }

    @Test func givenFeedBecomesUnavailable_whenPublished_thenSentenceShows() async {
        // given
        let useCase = NotifyingUseCase(permission: .allowed, feed: .available)
        let sut = GeneralSettingsVM(useCase: useCase)
        sut.didAppear()
        await waitUntil { sut.notificationRow?.state == .allowed }

        // when
        useCase.feedSubject.send(.unavailable)

        // then
        await waitUntil { sut.notificationRow?.state == .unavailable }
        #expect(sut.notificationRow?.detail == "This Harflow runtime can't send notifications. Update Harflow to use it.")
        #expect(sut.notificationSwitchesEnabled == false)
    }

    @Test func givenFeedUnavailableAtStart_whenPermissionDenied_thenUnavailableWins() async {
        // given
        let sut = GeneralSettingsVM(useCase: NotifyingUseCase(permission: .denied, feed: .unavailable))

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.notificationRow != nil }
        #expect(sut.notificationRow?.state == .unavailable)
        #expect(sut.notificationRow?.actionTitle == nil)
    }

    @Test func givenAppCannotPost_whenAppearing_thenNoRowAndSwitchesStayEnabled() async {
        // given
        let useCase = NotifyingUseCase(permission: nil)
        let sut = GeneralSettingsVM(useCase: useCase)

        // when
        sut.didAppear()
        await waitUntil { useCase.permissionReads == 1 }
        useCase.activationSubject.send()
        await waitUntil { useCase.permissionReads == 2 }

        // then
        #expect(sut.notificationRow == nil)
        #expect(sut.notificationSwitchesEnabled)
    }

    @Test func givenAUseCaseWithoutPermissionReading_whenAppearing_thenThereIsNoRow() {
        // given
        let useCase = MockGeneralSettingsUseCase()
        given(useCase).appAppearance.willReturn(.system)
        given(useCase).appAppearancePublisher().willReturn(Just(.system).eraseToAnyPublisher())
        given(useCase).openWindowOnStart.willReturn(true)
        given(useCase).notifyOnFinish.willReturn(true)
        given(useCase).notifyOnNeedsYou.willReturn(true)
        given(useCase).openWindowOnStartPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).notifyOnFinishPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).notifyOnNeedsYouPublisher().willReturn(Just(true).eraseToAnyPublisher())
        let sut = GeneralSettingsVM(useCase: useCase)

        // when
        sut.didAppear()

        // then
        #expect(sut.notificationRow == nil)
        #expect(sut.notificationSwitchesEnabled)
    }

    @Test func givenOpenSystemSettingsTapped_whenCalled_thenRoutingOnce() {
        // given
        let routing = MockNotificationSettingsRouting()
        given(routing).openNotificationSettings().willReturn()
        let sut = GeneralSettingsVM(useCase: NotifyingUseCase(permission: .denied), notificationRouting: routing)

        // when
        sut.didTapOpenNotificationSettings()

        // then
        verify(routing).openNotificationSettings().called(1)
    }
}
