import Combine
import Foundation
import HfRepository
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct GeneralSettingsViewRepositoryTests {
    
    private func makeSUT(
        settings: MockSettingsRepository = MockSettingsRepository(),
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        taskList: MockTaskListRepository = MockTaskListRepository(),
        backends: MockBackendsRepository = MockBackendsRepository(),
        install: MockInstallRepository = MockInstallRepository()
    ) -> GeneralSettingsViewRepository {
        GeneralSettingsViewRepository(
            settingsRepository: settings, toolEnvironmentRepository: toolEnvironment, taskListRepository: taskList,
            backendsRepository: backends, installRepository: install
        )
    }
    
    @Test func givenALocatedTool_whenResolved_thenItReturnsFound() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let locator = ToolLocator(overrideDirectory: nil, home: "/Users/test", uvToolBin: nil, isExecutable: { $0 == "/opt/homebrew/bin/harflow-ctl" })
        given(toolEnvironment).locator.willReturn(locator)
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        
        // when
        let resolution = sut.resolve("harflow-ctl")
        
        // then
        #expect(resolution == .found(path: "/opt/homebrew/bin/harflow-ctl"))
    }
    
    @Test func givenAMissingTool_whenResolved_thenItReturnsNotFound() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let locator = ToolLocator(overrideDirectory: nil, home: "/Users/test", uvToolBin: nil, isExecutable: { _ in false })
        given(toolEnvironment).locator.willReturn(locator)
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        
        // when
        let resolution = sut.resolve("harflow-ctl")
        
        // then
        #expect(resolution == .notFound)
    }
    
    @Test func givenSetToolDirectory_whenCalled_thenItWritesThroughAndTriggersARefreshOnly() {
        // given
        let settings = MockSettingsRepository()
        let taskList = MockTaskListRepository()
        let backends = MockBackendsRepository()
        given(settings).setToolDirectory(.value("/opt/homebrew/bin")).willReturn()
        given(taskList).settingsChanged().willReturn()
        given(backends).settingsChanged().willReturn()
        let sut = makeSUT(settings: settings, taskList: taskList, backends: backends)

        // when
        sut.setToolDirectory("/opt/homebrew/bin")

        // then — decision 11/F4-05: writes the setting, then refreshes the list (and the backends
        // catalog, Monitor piece 6) only.
        verify(settings).setToolDirectory(.value("/opt/homebrew/bin")).called(1)
        verify(taskList).settingsChanged().called(1)
        verify(backends).settingsChanged().called(1)
    }
    
    @Test func givenTheRepositoryProperties_whenRead_thenTheyPassThroughToSettingsRepository() {
        // given
        let settings = MockSettingsRepository()
        given(settings).toolDirectory.willReturn("/custom/bin")
        given(settings).openWindowOnStart.willReturn(false)
        given(settings).notifyOnFinish.willReturn(false)
        let sut = makeSUT(settings: settings)
        
        // then
        #expect(sut.toolDirectory == "/custom/bin")
        #expect(sut.openWindowOnStart == false)
        #expect(sut.notifyOnFinish == false)
    }

    @Test func givenRuntimeRetry_whenRequested_thenItForwardsToTheInstallRepository() async {
        // given
        let install = MockInstallRepository()
        given(install).retry().willReturn()
        let sut = makeSUT(install: install)

        // when
        await sut.retryRuntime()

        // then
        verify(install).retry().called(1)
    }

    @Test func givenRuntimeStatePublisher_whenRead_thenItPassesThroughTheInstallStatus() {
        // given
        let install = MockInstallRepository()
        let subject = PassthroughSubject<InstallState, Never>()
        given(install).statePublisher().willReturn(subject.eraseToAnyPublisher())
        let sut = makeSUT(install: install)
        var received: InstallState?
        let token = sut.installStatePublisher().sink { received = $0 }

        // when
        subject.send(.failed(stage: .harflow, message: "fixture runtime failure"))

        // then
        #expect(received == .failed(stage: .harflow, message: "fixture runtime failure"))
        withExtendedLifetime(token) {}
    }
}
