import Foundation
@testable import PbUtilities
import Testing

@Suite struct ArrayBuilderTests {
    
    private static func build(@ArrayBuilder<Int> _ builder: () -> [Int]) -> [Int] {
        builder()
    }
    
    @Test func givenOptionalAndPlainExpressions_whenBuilding_thenDropsNilAndKeepsOrder() {
        // given
        let flag = true
        
        // when
        let result = Self.build {
            1
            if flag { 2 }
            [3, 4]
            if !flag { 5 }
        }
        
        // then
        #expect(result == [1, 2, 3, 4])
    }
    
    @Test func givenALoop_whenBuilding_thenFlattensEachIteration() {
        // given / when
        let result = Self.build {
            for value in 1 ... 3 { value * 10 }
        }
        
        // then
        #expect(result == [10, 20, 30])
    }
}
