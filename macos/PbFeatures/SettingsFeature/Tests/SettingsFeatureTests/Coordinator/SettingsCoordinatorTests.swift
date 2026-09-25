import Mockable
import PbCommon
import PbCommonTestMock
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct SettingsCoordinatorTests {
    
    @Test func givenAPath_whenHandled_thenItBubblesToTheParent() {
        // given — `PathDestination` is not `Equatable`, so the captured argument (not `.value(...)`)
        // is how the bubble is verified.
        let parent = MockCoordinator()
        var captured: (any PathDestination)?
        given(parent)
            .handle(path: .any)
            .willProduce { captured = $0 }
        let sut = SettingsCoordinator(parent: parent)
        
        // when
        sut.handle(path: MonitorDestination.openWindow)
        
        // then — Settings owns no destination of its own, so every path bubbles up.
        #expect(captured?.pathId == MonitorDestination.openWindow.pathId)
    }
    
    @Test func givenTheCoordinator_whenBuildingEitherTab_thenAViewIsProduced() {
        // given
        let parent = MockCoordinator()
        let sut = SettingsCoordinator(parent: parent)
        
        // then — both build methods succeed without touching `GlobalValues` beyond their defaults.
        _ = sut.buildGeneralSettingsView()
        _ = sut.buildHarnessesView()
    }
    
    @Test func givenTheCoordinator_whenStarted_thenItProducesTheTabViewRoot() {
        // given
        let parent = MockCoordinator()
        let sut = SettingsCoordinator(parent: parent)
        
        // then
        _ = sut.start()
    }
}
