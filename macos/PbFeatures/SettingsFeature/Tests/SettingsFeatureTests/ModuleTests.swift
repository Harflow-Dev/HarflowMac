import PbCommon
@testable import SettingsFeature
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

    @Test func givenModuleInitialized_whenReadingGlobalValues_thenSettingsFeatureFactoryResolvesToTheRealImplementation() {
        // given
        let sut = Module()

        // when
        sut.initializeModule()

        // then
        #expect(GlobalValues.settingsFeatureFactory is SettingsFeatureFactoryImpl)
    }

    @Test func givenTheRegisteredFactory_whenAskedForACoordinator_thenItBuildsASettingsCoordinator() {
        // given
        let sut = Module()
        sut.initializeModule()
        let parent = DummyCoordinator()

        // when
        let coordinator = GlobalValues.settingsFeatureFactory.makeSettingsCoordinator(asChildOf: parent)

        // then
        #expect(coordinator is SettingsCoordinator)
    }
}
