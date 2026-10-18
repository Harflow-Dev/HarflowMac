import Foundation
@testable import PbCommon
import Testing

private struct FakeDestination: PathDestination, Equatable {
    let pathId: String
}

private struct ChildDestinationA: PathDestination {
    var pathId: String { "A" }
}

private struct ChildDestinationB: PathDestination {
    var pathId: String { "B" }
}

private struct CompositeFeatureDestination: CompositeDestination {
    var pathId: String { "composite" }
    static var children: [any PathDestination.Type] { [ChildDestinationA.self] }
}

@Suite struct PathDestinationTests {
    
    @Test func givenADestinationType_whenCheckingIsPartOfItsOwnInstance_thenReturnsTrue() {
        // given
        let destination = FakeDestination(pathId: "x")
        
        // when
        let isPart = FakeDestination.isPart(of: destination)
        
        // then
        #expect(isPart)
    }
    
    @Test func givenADestinationType_whenCheckingIsPartOfAnUnrelatedDestination_thenReturnsFalse() {
        // given
        let unrelated = ChildDestinationA()
        
        // when
        let isPart = FakeDestination.isPart(of: unrelated)
        
        // then
        #expect(!isPart)
    }
    
    @Test func givenACompositeDestination_whenCheckingIsPartOfItself_thenReturnsTrue() {
        // given / when / then
        #expect(CompositeFeatureDestination.isPart(of: CompositeFeatureDestination()))
    }
    
    @Test func givenACompositeDestination_whenCheckingIsPartOfARegisteredChild_thenReturnsTrue() {
        // given / when / then
        #expect(CompositeFeatureDestination.isPart(of: ChildDestinationA()))
    }
    
    @Test func givenACompositeDestination_whenCheckingIsPartOfAnUnregisteredChild_thenReturnsFalse() {
        // given / when / then
        #expect(!CompositeFeatureDestination.isPart(of: ChildDestinationB()))
    }
    
    @Test func givenTwoDestinations_whenCombinedWithPlus_thenProducesAnArrayInOrder() {
        // given
        let first = FakeDestination(pathId: "1")
        let second = FakeDestination(pathId: "2")
        
        // when
        let combined = (first + second).map(\.pathId)
        
        // then
        #expect(combined == ["1", "2"])
    }
    
    @Test func givenAnArrayAndAnOptionalDestination_whenCombinedWithPlus_thenAppendsOnlyWhenPresent() {
        // given
        let array: [any PathDestination] = [FakeDestination(pathId: "1")]
        let some: (any PathDestination)? = FakeDestination(pathId: "2")
        let none: (any PathDestination)? = nil
        
        // when / then
        #expect((array + some).map(\.pathId) == ["1", "2"])
        #expect((array + none).map(\.pathId) == ["1"])
    }
}
