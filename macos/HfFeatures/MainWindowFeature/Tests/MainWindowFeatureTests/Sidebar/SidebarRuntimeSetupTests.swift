import Combine
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct SidebarRuntimeSetupTests {
    private final class RuntimeUseCase: SidebarUseCase, RuntimeSetupObserving, @unchecked Sendable {
        var runtimeSetupState: RuntimeSetupState
        let runtimeSubject = PassthroughSubject<RuntimeSetupState, Never>()
        var installCount = 0

        init(_ state: RuntimeSetupState) { self.runtimeSetupState = state }
        var appAppearance: AppAppearance { .system }
        func appAppearancePublisher() -> AnyPublisher<AppAppearance, Never> { Just(.system).eraseToAnyPublisher() }
        func setAppAppearance(_: AppAppearance) {}
        func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { Just([]).eraseToAnyPublisher() }
        func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { Just(nil).eraseToAnyPublisher() }
        func hasListedPublisher() -> AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
        func titlesPublisher() -> AnyPublisher<[String: String], Never> { Just([:]).eraseToAnyPublisher() }
        var tasks: [TaskInfo] { [] }
        var listError: ToolError? { nil }
        var hasListed = false
        var connectionLine = "ready"
        var backendCatalog: BackendCatalog { .empty }
        func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { Just(.empty).eraseToAnyPublisher() }
        func title(_: String) -> String { "Task" }
        func runtimeSetupPublisher() -> AnyPublisher<RuntimeSetupState, Never> { runtimeSubject.eraseToAnyPublisher() }
        func installRuntime() async { installCount += 1 }
    }

    @Test func givenRuntimeNeedsInstallation_whenSidebarAppears_thenSetupActionIsShownAndInvoked() async {
        let useCase = RuntimeUseCase(.installationRequired(installedVersion: nil, requiredVersion: "0.0.2"))
        let routing = MockSidebarRouting()
        given(routing).selection.willReturn(nil)
        given(routing).selectionPublisher().willReturn(Just(nil).eraseToAnyPublisher())
        given(routing).pendingReveal.willReturn(nil)
        given(routing).revealPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(routing).consumeReveal(requestID: .any).willReturn()
        let sut = SidebarVM(
            useCase: useCase, routing: routing, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler()
        )
        sut.didAppear()
        await sut.waitForPresentation()

        #expect(sut.runtimeSetupState.actionTitle == "Install required components")
        sut.didTapRuntimeSetup()
        await waitUntil { useCase.installCount == 1 }
    }

    @Test func givenRuntimeIsReady_whenSidebarSetupActionIsTapped_thenNoInstallIsStarted() async {
        let useCase = RuntimeUseCase(.ready)
        let routing = MockSidebarRouting()
        given(routing).selection.willReturn(nil)
        given(routing).selectionPublisher().willReturn(Just(nil).eraseToAnyPublisher())
        given(routing).pendingReveal.willReturn(nil)
        given(routing).revealPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(routing).consumeReveal(requestID: .any).willReturn()
        let sut = SidebarVM(
            useCase: useCase, routing: routing, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler()
        )
        sut.didAppear()
        sut.didTapRuntimeSetup()
        await waitUntil { sut.runtimeSetupState == .ready }

        #expect(useCase.installCount == 0)
    }
}
