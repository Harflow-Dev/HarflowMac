import Combine
import Foundation
@testable import PbUtilities
import Testing

@Suite struct SubjectedTests {
    
    @Test func givenSubjected_whenGettingValue_thenReturnsInitialValue() {
        // given
        @Subjected var value = 10
        
        // then
        #expect(value == 10)
    }
    
    @Test func givenSubjected_whenSettingValue_thenUpdatesValue() {
        // given
        @Subjected var value = 10
        
        // when
        value = 20
        
        // then
        #expect(value == 20)
    }
    
    @Test func givenSubjected_whenSubscribed_thenReceivesValues() {
        // given
        @Subjected var value = 10
        var received: [Int] = []
        let cancellable = $value.sink { received.append($0) }
        
        // when
        value = 20
        value = 30
        
        // then
        #expect(received == [10, 20, 30])
        cancellable.cancel()
    }
    
    @Test func givenSubjectedInstances_whenComparing_thenUsesIdentity() {
        // given
        let first = Subjected(wrappedValue: 1)
        let second = Subjected(wrappedValue: 1)
        let alias = first
        
        // then
        #expect(first != second)
        #expect(first == alias)
    }
    
    @Test func givenPublisher_whenAssignedToSubjected_thenUpdatesSubjected() {
        // given
        let publisher = PassthroughSubject<Int, Never>()
        @Subjected var target = 0
        
        // when
        publisher.assign(to: $target)
        publisher.send(10)
        publisher.send(20)
        
        // then
        #expect(target == 20)
    }
    
    @Test func givenPublisher_whenUniquelyAssignedToSubjected_thenUpdatesSubjectedOnlyIfDifferent() {
        // given
        let publisher = PassthroughSubject<Int, Never>()
        @Subjected var target = 0
        var receivedCount = 0
        let cancellable = $target.sink { _ in receivedCount += 1 }
        
        // when
        publisher.uniqueAssign(to: $target)
        publisher.send(0) // should not trigger update
        publisher.send(10) // should trigger update
        publisher.send(10) // should not trigger update
        publisher.send(20) // should trigger update
        
        // then
        #expect(target == 20)
        #expect(receivedCount == 3) // initial (0) + 10 + 20
        cancellable.cancel()
    }
    
    @Test func givenSubjected_whenEncodingAndDecoding_thenPreservesValue() throws {
        // given
        @Subjected var original = 42
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // when
        let data = try encoder.encode($original)
        let decoded = try decoder.decode(Subjected<Int>.self, from: data)
        
        // then
        #expect(decoded.wrappedValue == 42)
    }
}
