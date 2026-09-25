import Foundation
@testable import MenuBarFeature
import Mockable
import PbCommon
import PbCommonTestMock
import Testing

@MainActor
@Suite struct MenuBarCoordinatorTests {
    
    /// A minimal `WindowPresenting` spy — `MockCoordinator` (`PbCommonTestMock`) does not itself
    /// conform to `WindowPresenting`, and the coordinator's `registerWindowOpener` needs a parent
    /// that does.
    final class WindowPresentingParent: Coordinator, WindowPresenting {
        var path: [PathDestination] = []
        private(set) var registeredOpener: (() -> Void)?
        private(set) var handledPaths: [String] = []
        
        func handle(path: any PathDestination) { handledPaths.append(path.pathId) }
        func handle(url _: URL) -> Bool { false }
        func registerWindowOpener(_ opener: @escaping () -> Void) { registeredOpener = opener }
    }
    
    @Test func givenAPath_whenHandled_thenItBubblesToTheParent() {
        // given
        let parent = WindowPresentingParent()
        let sut = MenuBarCoordinator(parent: parent)
        
        // when
        sut.handle(path: MonitorDestination.openWindow)
        
        // then
        #expect(parent.handledPaths == [MonitorDestination.openWindow.pathId])
    }
    
    @Test func givenSelect_whenCalled_thenItForwardsTheDestinationToTheParent() {
        // given
        let parent = WindowPresentingParent()
        let sut = MenuBarCoordinator(parent: parent)
        
        // when
        sut.select(.task("abc123"))
        
        // then
        #expect(parent.handledPaths == [MonitorDestination.task("abc123").pathId])
    }
    
    @Test func givenOpenWindow_whenCalled_thenItForwardsTheOpenWindowDestination() {
        // given
        let parent = WindowPresentingParent()
        let sut = MenuBarCoordinator(parent: parent)
        
        // when
        sut.openWindow()
        
        // then
        #expect(parent.handledPaths == [MonitorDestination.openWindow.pathId])
    }
    
    @Test func givenRegisterWindowOpener_whenTheParentConformsToWindowPresenting_thenItForwards() {
        // given
        let parent = WindowPresentingParent()
        let sut = MenuBarCoordinator(parent: parent)
        var opened = false
        
        // when
        sut.registerWindowOpener { opened = true }
        parent.registeredOpener?()
        
        // then
        #expect(opened)
    }
    
    @Test func givenRegisterWindowOpener_whenTheParentDoesNotConform_thenNothingCrashes() {
        // given — a plain `MockCoordinator` (does not conform to `WindowPresenting`).
        let parent = MockCoordinator()
        let sut = MenuBarCoordinator(parent: parent)
        
        // then — the downcast fails silently, exactly as documented.
        sut.registerWindowOpener {}
    }
    
    @Test func givenTheCoordinator_whenBuildingLabelAndContent_thenBothViewsAreProduced() {
        // given
        let parent = WindowPresentingParent()
        let sut = MenuBarCoordinator(parent: parent)
        
        // then — both share the coordinator's one lazily-built `MenuBarVM` (see `sharedVM()`);
        // producing both views must not crash or double-construct in a way that throws.
        _ = sut.buildMenuBarLabelView()
        _ = sut.buildMenuBarContentView()
    }
}
