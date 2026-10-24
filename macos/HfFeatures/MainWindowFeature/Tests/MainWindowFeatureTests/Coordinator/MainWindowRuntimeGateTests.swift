import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor
@Suite struct MainWindowRuntimeGateTests {
    private final class InstallFixture: InstallRepository, @unchecked Sendable {
        var setupState: RuntimeSetupState
        let setupSubject = PassthroughSubject<RuntimeSetupState, Never>()

        init(_ state: RuntimeSetupState) { self.setupState = state }
        func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> { setupSubject.eraseToAnyPublisher() }
        var state: InstallState { .installed }
        func statePublisher() -> AnyPublisher<InstallState, Never> { Just(.installed).eraseToAnyPublisher() }
        var lastCheckMessage: String? { nil }
        func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        var installAnywayBlockedMessage: String? { nil }
        func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        func destination() -> String? { nil }
        func install() async {}
        func installUvThenHarflow() async {}
        func retry() async {}
        func checkAgain() async {}
        func installAnyway() async -> Bool { false }
        func reset() {}
    }

    @Test func givenRuntimeIsNotReady_whenPresentingOrRoutingCreation_thenCreationIsBlocked() {
        let install = InstallFixture(.installationRequired(installedVersion: nil, requiredVersion: "0.0.2"))
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent, installRepository: install)

        sut.presentedSheet = .newSession
        sut.handle(path: MonitorDestination.newSession)
        sut.handle(path: MonitorDestination.newWorkflow(UUID()))
        sut.handle(path: MonitorDestination.workflow("draft"))

        #expect(!sut.runtimeIsReady)
        #expect(sut.presentedSheet == nil)
        #expect(sut.selection == nil)
    }

    @Test func givenRuntimeBecomesReady_whenCreationIsRequested_thenCreationIsRestored() async {
        let install = InstallFixture(.installationRequired(installedVersion: "0.0.1", requiredVersion: "0.0.2"))
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install)
        install.setupState = .ready
        install.setupSubject.send(.ready)
        await waitUntil { sut.runtimeIsReady }

        sut.handle(path: MonitorDestination.newSession)

        #expect(sut.runtimeIsReady)
        #expect(sut.presentedSheet == .newSession)
    }
}
