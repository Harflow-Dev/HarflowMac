import Combine
import Foundation
import Mockable
import MonitorCore
import PbRepository
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct GeneralSettingsViewRepositoryTests {
    
    private func makeSUT(
        settings: MockSettingsRepository = MockSettingsRepository(),
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        taskList: MockTaskListRepository = MockTaskListRepository(),
        backends: MockBackendsRepository = MockBackendsRepository()
    ) -> GeneralSettingsViewRepository {
        GeneralSettingsViewRepository(
            settingsRepository: settings, toolEnvironmentRepository: toolEnvironment, taskListRepository: taskList, backendsRepository: backends
        )
    }
    
    @Test func givenALocatedTool_whenResolved_thenItReturnsFound() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let locator = ToolLocator(overrideDirectory: nil, home: "/Users/test", uvToolBin: nil, isExecutable: { $0 == "/opt/homebrew/bin/polybridge-ctl" })
        given(toolEnvironment).locator.willReturn(locator)
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        
        // when
        let resolution = sut.resolve("polybridge-ctl")
        
        // then
        #expect(resolution == .found(path: "/opt/homebrew/bin/polybridge-ctl"))
    }
    
    @Test func givenAMissingTool_whenResolved_thenItReturnsNotFound() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let locator = ToolLocator(overrideDirectory: nil, home: "/Users/test", uvToolBin: nil, isExecutable: { _ in false })
        given(toolEnvironment).locator.willReturn(locator)
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        
        // when
        let resolution = sut.resolve("polybridge-ctl")
        
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
}
