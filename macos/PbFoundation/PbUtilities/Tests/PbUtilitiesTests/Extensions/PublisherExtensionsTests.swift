import Combine
import Foundation
@testable import PbUtilities
import Testing

@Suite struct PublisherExtensionsTests {
    
    @MainActor
    private final class Target {
        var value: Int = 0
    }
    
    @Test @MainActor func givenPublisher_whenWeakAssigned_thenUpdatesTargetProperty() {
        // given
        let subject = PassthroughSubject<Int, Never>()
        let target = Target()
        let cancellable = subject.weakAssign(to: \.value, on: target)
        
        // when
        subject.send(5)
        subject.send(9)
        
        // then
        #expect(target.value == 9)
        cancellable.cancel()
    }
    
    @Test @MainActor func givenPublisher_whenWeakAssignedAndTargetDeallocated_thenDoesNotCrash() {
        // given
        let subject = PassthroughSubject<Int, Never>()
        var target: Target? = Target()
        let cancellable = subject.weakAssign(to: \.value, on: target!)
        
        // when
        target = nil
        subject.send(1)
        
        // then
        #expect(Bool(true)) // no crash
        cancellable.cancel()
    }
    
    @Test @MainActor func givenPublisher_whenTapWeakAssigned_thenUpdatesTargetAndForwardsOutput() {
        // given
        let subject = PassthroughSubject<Int, Never>()
        let target = Target()
        var forwarded: [Int] = []
        let cancellable = subject
            .tapWeakAssign(to: \.value, on: target)
            .sink { forwarded.append($0) }
        
        // when
        subject.send(3)
        subject.send(7)
        
        // then
        #expect(target.value == 7)
        #expect(forwarded == [3, 7])
        cancellable.cancel()
    }
}
