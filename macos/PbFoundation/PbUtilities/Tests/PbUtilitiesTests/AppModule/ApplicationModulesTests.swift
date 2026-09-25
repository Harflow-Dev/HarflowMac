import Foundation
import Mockable
@testable import PbUtilities
import Testing

@MainActor
@Suite struct ApplicationModulesTests {
    
    @Test func givenModules_whenInitializing_thenCallsLifecycleMethodsInPhaseOrder() {
        // given
        let mock1 = makeMockModule()
        let mock2 = makeMockModule()
        let modules = ApplicationModules(mock1, mock2)
        
        // when
        modules.initialize()
        
        // then
        verify(mock1).modulesWillInitialize().called(1)
        verify(mock1).initializeModule().called(1)
        verify(mock1).modulesDidInitialize().called(1)
        verify(mock2).modulesWillInitialize().called(1)
        verify(mock2).initializeModule().called(1)
        verify(mock2).modulesDidInitialize().called(1)
    }
    
    @Test func givenMultipleModules_whenInitializing_thenEveryModuleFinishesWillInitializeBeforeAnyInitializeModule() {
        // given — stub directly (not via makeMockModule(), whose default `.willReturn()` stubs
        // would otherwise win over these `.willProduce` closures).
        var callOrder: [String] = []
        let mock1 = MockPbModuleDelegate()
        given(mock1).modulesWillInitialize().willProduce { callOrder.append("1.willInitialize") }
        given(mock1).initializeModule().willProduce { callOrder.append("1.initializeModule") }
        given(mock1).modulesDidInitialize().willProduce { callOrder.append("1.didInitialize") }
        let mock2 = MockPbModuleDelegate()
        given(mock2).modulesWillInitialize().willProduce { callOrder.append("2.willInitialize") }
        given(mock2).initializeModule().willProduce { callOrder.append("2.initializeModule") }
        given(mock2).modulesDidInitialize().willProduce { callOrder.append("2.didInitialize") }
        let modules = ApplicationModules(mock1, mock2)
        
        // when
        modules.initialize()
        
        // then — lowest layer (mock1) finishes each phase before the next phase starts for anyone,
        // so a later module's initializeModule() can resolve a value the earlier module registered.
        #expect(callOrder == [
            "1.willInitialize", "2.willInitialize",
            "1.initializeModule", "2.initializeModule",
            "1.didInitialize", "2.didInitialize"
        ])
    }
    
    @Test func givenModules_whenLaunched_thenCallsLaunched() {
        // given
        let mock = makeMockModule()
        let modules = ApplicationModules(mock)
        
        // when
        modules.launched()
        
        // then
        verify(mock).launched().called(1)
    }
    
    @Test func givenModules_whenEnteringBackground_thenCallsEnteringBackground() {
        // given
        let mock = makeMockModule()
        let modules = ApplicationModules(mock)
        
        // when
        modules.enteringBackground()
        
        // then
        verify(mock).enteringBackground().called(1)
    }
    
    @Test func givenModules_whenEnteringForeground_thenCallsEnteringForeground() {
        // given
        let mock = makeMockModule()
        let modules = ApplicationModules(mock)
        
        // when
        modules.enteringForeground()
        
        // then
        verify(mock).enteringForeground().called(1)
    }
    
    @Test func givenModules_whenApplicationWillTerminate_thenCallsWillTerminate() {
        // given
        let mock = makeMockModule()
        let modules = ApplicationModules(mock)
        
        // when
        modules.applicationWillTerminate()
        
        // then
        verify(mock).applicationWillTerminate().called(1)
    }
    
    @Test func givenMixedInitializedModules_whenReinitializingIfNeeded_thenOnlyCallsUninitialized() {
        // given
        let mockInitialized = makeMockModule(isInitialized: true)
        let mockUninitialized = makeMockModule(isInitialized: false)
        let modules = ApplicationModules(mockInitialized, mockUninitialized)
        
        // when
        modules.reinitializeIfNeeded()
        
        // then
        verify(mockInitialized).initializeModule().called(0)
        verify(mockUninitialized).initializeModule().called(1)
    }
    
    // MARK: - Test Helpers
    
    private func makeMockModule(isInitialized: Bool = false) -> MockPbModuleDelegate {
        let mock = MockPbModuleDelegate()
        given(mock).isInitialized.willReturn(isInitialized)
        given(mock).launched().willReturn()
        given(mock).modulesWillInitialize().willReturn()
        given(mock).initializeModule().willReturn()
        given(mock).modulesDidInitialize().willReturn()
        given(mock).enteringBackground().willReturn()
        given(mock).enteringForeground().willReturn()
        given(mock).applicationWillTerminate().willReturn()
        return mock
    }
}
