import Foundation
@testable import PbCommon
import Testing

private struct FakeDestination: PathDestination, Equatable {
    let pathId: String
}

@MainActor
private final class SpyCoordinator: Coordinator {
    var path: [PathDestination] = []
    private(set) var handledPathIds: [String] = []
    private(set) var handledURLs: [URL] = []
    
    func handle(path: PathDestination) {
        handledPathIds.append(path.pathId)
    }
    
    func handle(url: URL) -> Bool {
        handledURLs.append(url)
        return true
    }
}

@MainActor
private final class SpyParentCoordinator: Coordinator, ParentCoordinator {
    var path: [PathDestination] = []
    var activeChild: ChildCoordinator?
    private(set) var stoppedChildren: [ObjectIdentifier] = []
    
    func handle(path: PathDestination) {}
    func handle(url: URL) -> Bool { false }
    
    func childDidStop(_ child: ChildCoordinator) {
        stoppedChildren.append(ObjectIdentifier(child))
    }
}

@MainActor
private final class TestChildCoordinator: ChildCoordinator {
    let parent: Coordinator
    var path: [PathDestination] = []
    
    init(parent: Coordinator) {
        self.parent = parent
    }
}

@MainActor
@Suite struct CoordinatorBubblingTests {
    
    @Test func givenAChildCoordinator_whenRoutingToADestination_thenBubblesUpToTheRootsHandlePath() {
        // given
        let root = SpyCoordinator()
        let child = TestChildCoordinator(parent: root)
        
        // when
        child.route(to: FakeDestination(pathId: "task:abc"))
        
        // then
        #expect(root.handledPathIds == ["task:abc"])
    }
    
    @Test func givenAChildOfAChild_whenRoutingToADestination_thenBubblesAllTheWayToTheRoot() {
        // given
        let root = SpyCoordinator()
        let middle = TestChildCoordinator(parent: root)
        let leaf = TestChildCoordinator(parent: middle)
        
        // when
        leaf.route(to: FakeDestination(pathId: "deep"))
        
        // then
        #expect(root.handledPathIds == ["deep"])
    }
    
    @Test func givenAChildCoordinator_whenHandlingAURL_thenDelegatesToTheRoot() {
        // given
        let root = SpyCoordinator()
        let child = TestChildCoordinator(parent: root)
        let url = URL(string: "polybridge-monitor://task/abc")!
        
        // when
        let handled = child.handle(url: url)
        
        // then
        #expect(handled)
        #expect(root.handledURLs == [url])
    }
    
    @Test func givenAChildCoordinator_whenStopped_thenNotifiesItsParent() {
        // given
        let parent = SpyParentCoordinator()
        let child = TestChildCoordinator(parent: parent)
        
        // when
        child.stop()
        
        // then
        #expect(parent.stoppedChildren == [ObjectIdentifier(child)])
    }
    
    @Test func givenAParentWithAnActiveChild_whenReadingFullPath_thenAppendsTheChildsPath() {
        // given
        let parent = SpyParentCoordinator()
        parent.path = [FakeDestination(pathId: "root")]
        let child = TestChildCoordinator(parent: parent)
        child.path = [FakeDestination(pathId: "child")]
        parent.activeChild = child
        
        // when
        let fullPath = parent.fullPath.map(\.pathId)
        
        // then
        #expect(fullPath == ["root", "child"])
    }
    
    @Test func givenAParentWithNoActiveChild_whenReadingFullPath_thenReturnsOnlyItsOwnPath() {
        // given
        let parent = SpyParentCoordinator()
        parent.path = [FakeDestination(pathId: "root")]
        
        // when
        let fullPath = parent.fullPath.map(\.pathId)
        
        // then
        #expect(fullPath == ["root"])
    }
}
