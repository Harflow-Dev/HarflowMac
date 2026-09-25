import Foundation
@testable import PbRepository
import SwiftEnvironment
import Testing

// MARK: - ModuleTests

/// `.serialized` because this suite is the one place in this package that touches the process-global
/// `GlobalValues` registry (F11's rule) — there is no public `GlobalValues.reset()` to save/restore
/// around (unlike `ApplicationModulesTests`, which never touches it), so registrations made here are
/// process-lifetime. Nothing else in this package reads from `GlobalValues` (every other test
/// constructs its repository directly), so this is safe without a reset.
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

    @Test func givenModuleInitialized_whenReadingGlobalValues_thenEveryRepositoryResolvesToItsRealImplementation() {
        // given
        let sut = Module()

        // when
        sut.initializeModule()

        // then — every `@GlobalEntry` now resolves to a real impl, not the `Null*` default.
        #expect(GlobalValues.scheduling is SystemScheduler)
        #expect(GlobalValues.settingsRepository is SettingsRepositoryImpl)
        #expect(GlobalValues.toolEnvironmentRepository is ToolEnvironmentRepositoryImpl)
        #expect(GlobalValues.taskSnapshotRepository is TaskSnapshotRepositoryImpl)
        #expect(GlobalValues.eventStreamRepository is EventStreamRepositoryImpl)
        #expect(GlobalValues.finishNotifier is FinishNotifierImpl)
        #expect(GlobalValues.taskListRepository is TaskListRepositoryImpl)
        #expect(GlobalValues.taskActionRepository is TaskActionRepositoryImpl)
        #expect(GlobalValues.gitChangesRepository is GitChangesRepositoryImpl)
        #expect(GlobalValues.filePreviewRepository is FilePreviewRepositoryImpl)
        #expect(GlobalValues.harnessRepository is HarnessRepositoryImpl)
    }
}
