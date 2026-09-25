import Foundation
@testable import PbRepository
@testable import PbTerminal
import SwiftEnvironment
import Testing

// MARK: - ModuleTests

/// `.serialized`, same reasoning as `PbRepositoryTests/ModuleTests.swift`: this is the one place in
/// this package that touches the process-global `GlobalValues` registry. `PbRepository.Module` runs
/// first — decision 13, lowest layer first — since `PbTerminal.Module` reads its repositories back
/// out of `GlobalValues` rather than taking them as constructor parameters.
@Suite(.serialized)
@MainActor
struct ModuleTests {

    @Test func givenAFreshModule_whenInitializing_thenItMarksItselfInitialized() {
        // given
        PbRepository.Module().initializeModule()
        let sut = PbTerminal.Module()

        // when
        sut.initializeModule()

        // then
        #expect(sut.isInitialized)
    }

    @Test func givenModuleInitialized_whenReadingGlobalValues_thenTheRegistryAndTakeoverServiceResolveToTheirRealImplementations() {
        // given
        PbRepository.Module().initializeModule()
        let sut = PbTerminal.Module()

        // when
        sut.initializeModule()

        // then
        #expect(GlobalValues.terminalSessionRegistry is TerminalSessionRegistryImpl)
        #expect(GlobalValues.takeoverService is TakeoverServiceImpl)
    }
}
