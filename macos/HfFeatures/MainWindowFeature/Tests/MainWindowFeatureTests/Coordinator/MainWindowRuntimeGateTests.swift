import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct MainWindowRuntimeGateTests {
    private final class RefreshCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private final class InstallFixture: InstallRepository, @unchecked Sendable {
        var setupState: RuntimeSetupState
        let setupSubject = PassthroughSubject<RuntimeSetupState, Never>()
        let installCounter = RefreshCounter()

        init(_ state: RuntimeSetupState) { self.setupState = state }
        func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> { setupSubject.eraseToAnyPublisher() }
        var state: InstallState { .installed }
        func statePublisher() -> AnyPublisher<InstallState, Never> { Just(.installed).eraseToAnyPublisher() }
        var lastCheckMessage: String? { nil }
        func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        var installAnywayBlockedMessage: String? { nil }
        func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        func destination() -> String? { nil }
        func install() async { installCounter.increment() }
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
        #expect(sut.presentedSheet == nil)
        #expect(sut.selection == .newSession)
    }

    @Test func givenQualifiedRuntimeBeforeFirstListing_whenReadFailsAndRetries_thenSetupIsNotRequested() async {
        // given
        let install = InstallFixture(.ready)
        let listing = MockTaskListRepository()
        let listed = CurrentValueSubject<Bool, Never>(false)
        let errors = CurrentValueSubject<ToolError?, Never>(nil)
        given(listing).hasListed.willReturn(false)
        given(listing).listError.willReturn(nil)
        given(listing).tasksPublisher().willReturn(Empty<[TaskInfo], Never>().eraseToAnyPublisher())
        given(listing).tasks.willReturn([])
        given(listing).hasListedPublisher().willReturn(listed.eraseToAnyPublisher())
        given(listing).listErrorPublisher().willReturn(errors.eraseToAnyPublisher())
        let refreshes = RefreshCounter()
        given(listing).refreshAndWait().willProduce { refreshes.increment(); return .success(()) }
        let sut = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install, taskListRepository: listing)
        // when
        errors.send(.timedOut(tool: "harflow-ctl task-list-page", seconds: 30))
        await waitUntil { sut.loadingWorkError != nil }
        // then
        #expect(sut.runtimeIsReady)
        #expect(sut.runtimeSetupState == .ready)
        #expect(!sut.hasLoadedWork)
        #expect(install.installCounter.value == 0)
        sut.retryLoadingWork()
        await waitUntil { refreshes.value == 1 }
        // when
        listed.send(true)
        errors.send(nil)
        await waitUntil { sut.hasLoadedWork && sut.loadingWorkError == nil }
        sut.selection = .task("retained")
        errors.send(.timedOut(tool: "harflow-ctl task-list-page", seconds: 30))
        await waitUntil { sut.loadingWorkError != nil }
        // then
        #expect(sut.hasLoadedWork)
        #expect(sut.selection == .task("retained"))
        #expect(install.installCounter.value == 0)
        #expect(sut.runtimeIsReady)
    }

}
