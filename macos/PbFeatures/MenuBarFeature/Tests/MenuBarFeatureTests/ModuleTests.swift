@testable import MenuBarFeature
import PbCommon
import SwiftEnvironment
import Testing

/// `.serialized`: touches process-global `GlobalValues`, same rule as `PbRepositoryTests.ModuleTests`.
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
    
    @Test func givenModuleInitialized_whenReadingGlobalValues_thenMenuBarFeatureFactoryResolvesToTheRealImplementation() {
        // given
        let sut = Module()
        
        // when
        sut.initializeModule()
        
        // then
        #expect(GlobalValues.menuBarFeatureFactory is MenuBarFeatureFactoryImpl)
    }
    
    @Test func givenTheRegisteredFactory_whenAskedForACoordinator_thenItBuildsAMenuBarCoordinator() {
        // given
        let sut = Module()
        sut.initializeModule()
        let parent = DummyCoordinator()
        
        // when
        let coordinator = GlobalValues.menuBarFeatureFactory.makeMenuBarCoordinator(asChildOf: parent)
        
        // then
        #expect(coordinator is MenuBarCoordinator)
    }
}
