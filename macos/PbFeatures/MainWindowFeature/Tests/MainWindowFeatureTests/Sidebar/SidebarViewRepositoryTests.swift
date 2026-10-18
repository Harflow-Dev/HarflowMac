import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import Testing

@MainActor
@Suite struct SidebarViewRepositoryTests {
    
    @Test func givenTheProperties_whenRead_thenTheyPassThroughToTaskListRepository() {
        // given
        let taskList = MockTaskListRepository()
        given(taskList).tasks.willReturn([])
        given(taskList).listError.willReturn(nil)
        given(taskList).hasListed.willReturn(true)
        given(taskList).connectionLine.willReturn("connected")
        given(taskList).title(.value("abc123")).willReturn("Fix the bug")
        let sut = SidebarViewRepository(taskListRepository: taskList)
        
        // then
        #expect(sut.tasks.isEmpty)
        #expect(sut.listError == nil)
        #expect(sut.hasListed)
        #expect(sut.connectionLine == "connected")
        #expect(sut.title("abc123") == "Fix the bug")
    }
    
    @Test func givenThePublishers_whenSubscribed_thenTheyForwardTaskListValues() {
        // given
        let taskList = MockTaskListRepository()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        given(taskList).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(taskList).listErrorPublisher().willReturn(Just(nil).eraseToAnyPublisher())
        given(taskList).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
        let sut = SidebarViewRepository(taskListRepository: taskList)
        var received: [TaskInfo]?
        let cancellable = sut.tasksPublisher().sink { received = $0 }
        
        // when
        let task = TaskInfo(.object(["task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running")]))!
        tasksSubject.send([task])
        
        // then
        #expect(received == [task])
        cancellable.cancel()
    }
    
    @Test func givenTitlesPublisher_whenSubscribed_thenItForwardsTaskListTitles() {
        // given — F4-11/MS-LIST-5: titles load off-main separately from the listing, so this
        // publisher has to exist and forward independently of `tasksPublisher`.
        let taskList = MockTaskListRepository()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        given(taskList).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        let sut = SidebarViewRepository(taskListRepository: taskList)
        var received: [String: String]?
        let cancellable = sut.titlesPublisher().sink { received = $0 }
        
        // when
        titlesSubject.send(["abc123": "Fix the bug"])
        
        // then
        #expect(received == ["abc123": "Fix the bug"])
        cancellable.cancel()
    }
    
    // MARK: - Install (settled plan, section 5)

    @Test func givenInstallRepositoryValues_whenReadOrActed_thenTheyPassThrough() async {
        // given
        let install = MockInstallRepository()
        given(install).state.willReturn(.needsUv)
        given(install).lastCheckMessage.willReturn("checking")
        given(install).installAnywayBlockedMessage.willReturn("blocked")
        given(install).destination().willReturn("/Users/x/.local/bin")
        given(install).statePublisher().willReturn(Just(InstallState.needsUv).eraseToAnyPublisher())
        given(install).lastCheckMessagePublisher().willReturn(Just("checking").eraseToAnyPublisher())
        given(install).installAnywayBlockedMessagePublisher().willReturn(Just("blocked").eraseToAnyPublisher())
        given(install).install().willReturn()
        given(install).installUvThenPolybridge().willReturn()
        given(install).retry().willReturn()
        given(install).checkAgain().willReturn()
        given(install).installAnyway().willReturn(true)
        given(install).reset().willReturn()
        let sut = SidebarViewRepository(installRepository: install)

        // then — reads
        #expect(sut.installState == .needsUv)
        #expect(sut.lastCheckMessage == "checking")
        #expect(sut.installAnywayBlockedMessage == "blocked")
        #expect(sut.installDestination() == "/Users/x/.local/bin")
        var receivedState: InstallState?
        let cancellable = sut.installStatePublisher().sink { receivedState = $0 }
        #expect(receivedState == .needsUv)

        // when — actions
        await sut.install()
        await sut.installUvThenPolybridge()
        await sut.retry()
        await sut.checkAgain()
        let allowed = await sut.installAnyway()
        sut.reset()

        // then
        #expect(allowed)
        verify(install).install().called(1)
        verify(install).installUvThenPolybridge().called(1)
        verify(install).retry().called(1)
        verify(install).checkAgain().called(1)
        verify(install).installAnyway().called(1)
        verify(install).reset().called(1)
        cancellable.cancel()
    }

    @Test func givenBothToolsMissing_whenInstallNeedIsComputed_thenTheClassifierSaysMissing() {
        // given — `installNeed(for:)` locates both tools fresh through `ToolEnvironmentRepository`
        // rather than trusting the error's own claim, then hands the classifier both presences.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).locator.willReturn(
            ToolLocator(overrideDirectory: nil, home: "/Users/x", uvToolBin: nil, isExecutable: { _ in false })
        )
        let sut = SidebarViewRepository(toolEnvironmentRepository: toolEnvironment)

        // when
        let need = sut.installNeed(for: .notFound(tool: "polybridge-ctl", searched: []))

        // then
        #expect(need == .missing)
    }

    @Test func givenOnlyOneToolFound_whenInstallNeedIsComputed_thenTheClassifierSaysIncomplete() {
        // given — `polybridge-setup` located, `polybridge-ctl` not: one missing is `.incomplete`,
        // regardless of which tool the error itself named.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).locator.willReturn(
            ToolLocator(overrideDirectory: nil, home: "/Users/x", uvToolBin: nil, isExecutable: { $0 == "/Users/x/.local/bin/polybridge-setup" })
        )
        let sut = SidebarViewRepository(toolEnvironmentRepository: toolEnvironment)

        // when
        let need = sut.installNeed(for: .notFound(tool: "polybridge-ctl", searched: []))

        // then
        #expect(need == .incomplete)
    }

    // MARK: - Backend catalog (Monitor piece 6)

    @Test func givenBackendCatalogValues_whenReadOrSubscribed_thenTheyPassThroughToBackendsRepository() {
        // given
        let backends = MockBackendsRepository()
        let catalog = BackendCatalog(entries: [BackendCatalogEntry(backend: "claude", installed: true)], state: .available)
        given(backends).catalog.willReturn(catalog)
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        given(backends).catalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        let sut = SidebarViewRepository(backendsRepository: backends)

        // then — the synchronous snapshot passes through.
        #expect(sut.backendCatalog == catalog)

        // when — so does the publisher.
        var received: BackendCatalog?
        let cancellable = sut.backendCatalogPublisher().sink { received = $0 }
        let updated = BackendCatalog(entries: [], state: .degraded)
        catalogSubject.send(updated)

        // then
        #expect(received == updated)
        cancellable.cancel()
    }

    @Test func givenANonInstallToolError_whenInstallNeedIsComputed_thenItIsNil() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).locator.willReturn(
            ToolLocator(overrideDirectory: nil, home: "/Users/x", uvToolBin: nil, isExecutable: { _ in false })
        )
        let sut = SidebarViewRepository(toolEnvironmentRepository: toolEnvironment)

        // when
        let need = sut.installNeed(for: .refused(code: "denied", message: "no"))

        // then
        #expect(need == nil)
    }
}
