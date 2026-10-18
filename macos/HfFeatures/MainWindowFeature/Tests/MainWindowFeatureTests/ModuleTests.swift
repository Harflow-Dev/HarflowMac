import HfCommon
import HfCommonTestMock
@testable import MainWindowFeature
import SwiftEnvironment
import Testing

/// `.serialized`: touches process-global `GlobalValues`, same rule as `HfRepositoryTests.ModuleTests`.
@Suite(.serialized)
@MainActor
struct ModuleTests {
    
    @Test func givenAFreshModule_whenInitializing_thenItMarksItselfInitialized() {
        // given
        let sut = Module()
        
        // when
        sut.initializeModule()
        
        // then
        #expect(sut.isInitialized)
    }
    
    @Test func givenModuleInitialized_whenReadingGlobalValues_thenMainWindowFeatureFactoryResolvesToTheRealImplementation() {
        // given
        let sut = Module()
        
        // when
        sut.initializeModule()
        
        // then
        #expect(GlobalValues.mainWindowFeatureFactory is MainWindowFeatureFactoryImpl)
    }
    
    @Test func givenTheRegisteredFactory_whenAskedForACoordinator_thenItBuildsAMainWindowCoordinator() {
        // given
        let sut = Module()
        sut.initializeModule()
        let parent = MockCoordinator()
        
        // when
        let coordinator = GlobalValues.mainWindowFeatureFactory.makeMainWindowCoordinator(asChildOf: parent)
        
        // then
        #expect(coordinator is MainWindowCoordinator)
    }
}
