import Combine
import Foundation
import HfRepository
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

private let gateContract = ToolError.unsupportedVersion(tool: "harflow-ctl", version: "2")
private let gateCapability = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-list-page", detail: "unrecognized")
private let gateStoreRefusal = ToolError.structuredRefusal(
    code: "state_incompatible",
    message: "Unsupported state root: foreign store marker; inspect state or select a fresh state root",
    data: ["reason": .string("foreign_store"), "state_root": .string("/Users/me/Library/Application Support/Harflow/State")]
)

@MainActor
@Suite struct MenuBarViewRepositoryTests {
    
    @Test func givenTheProperties_whenRead_thenTheyPassThroughToTheRepositories() {
        // given
        let taskList = MockTaskListRepository()
        given(taskList).connectionLine.willReturn("connected")
        given(taskList).runningCount.willReturn(2)
        given(taskList).title(.value("abc123")).willReturn("Fix the bug")
        let sut = MenuBarViewRepository(taskListRepository: taskList)
        
        // then
        #expect(sut.connectionLine == "connected")
        #expect(sut.runningCount == 2)
        #expect(sut.title("abc123") == "Fix the bug")
    }
    
    @Test func givenSetupState_whenRead_thenItPassesThrough() {
        // given
        let install = MockInstallRepository()
        given(install).setupState.willReturn(.checking)
        let sut = MenuBarViewRepository(installRepository: install)

        // then
        #expect(sut.runtimeSetupState == .checking)
    }

    @Test(arguments: [
        (RuntimeSetupState.ready, ToolError?.none, StoreRecoveryState.idle, true),
        (.ready, .some(ToolError.timedOut(tool: "harflow-ctl", seconds: 30)), .idle, true),
        (.ready, .some(ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "")), .idle, true),
        (.ready, .some(gateContract), .idle, false),
        (.ready, .some(gateCapability), .idle, false),
        (.ready, nil, .incompatible(gateStoreRefusal), false),
        (.checking, nil, .idle, false),
        (.installing, nil, .idle, false),
        (.installationRequired(installedVersion: nil, requiredVersion: "0.0.14"), nil, .idle, false),
        (.failed("x"), nil, .idle, false)
    ])
    func givenEachGateInput_whenWorkAvailabilityMapped_thenMatchesMainWindowGate(
        setup: RuntimeSetupState, listError: ToolError?, store: StoreRecoveryState, expected: Bool
    ) {
        // when
        let available = MenuBarViewRepository.workAvailability(setup: setup, listError: listError, store: store)

        // then
        #expect(available == expected)
        if setup.isReady {
            #expect(available == (MainWindowGate.classify(runtimeReady: true, listError: listError, storeState: store) == nil))
        }
    }

    @Test func givenTheSynchronousInputs_whenWorkAvailableIsRead_thenItFollowsThem() {
        // given
        let install = MockInstallRepository()
        given(install).setupState.willReturn(.ready)
        let taskList = MockTaskListRepository()
        given(taskList).listError.willReturn(gateContract)
        let recovery = MockStateRecoveryRepository()
        given(recovery).state.willReturn(.idle)
        let sut = MenuBarViewRepository(taskListRepository: taskList, installRepository: install, stateRecoveryRepository: recovery)

        // then
        #expect(sut.workAvailable == false)
    }

    /// Built outside the main actor so the sink closure is not main-actor isolated and may receive off the main thread.
    private nonisolated static func collect(_ publisher: AnyPublisher<Bool, Never>, into box: LockedBox<[Bool]>) -> AnyCancellable {
        publisher.sink { value in box.mutate { $0.append(value) } }
    }

    @Test func givenAnOffMainSetupState_whenWorkAvailabilityPublishes_thenNoMainActorTrap() async {
        // given
        let setup = PassthroughSubject<RuntimeSetupState, Never>()
        let listErrors = CurrentValueSubject<ToolError?, Never>(nil)
        let stores = CurrentValueSubject<StoreRecoveryState, Never>(.idle)
        let received = LockedBox<[Bool]>([])
        let token = Self.collect(
            MenuBarViewRepository.workAvailability(
                setup: setup.eraseToAnyPublisher(), listErrors: listErrors.eraseToAnyPublisher(), stores: stores.eraseToAnyPublisher()
            ),
            into: received
        )

        // when
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                setup.send(.checking)
                setup.send(.ready)
                setup.send(.ready)
                listErrors.send(gateContract)
                listErrors.send(nil)
                setup.send(.checking)
                continuation.resume()
            }
        }

        // then — duplicates are dropped and the contract gate flips availability.
        #expect(received.value == [false, true, false, true, false])
        withExtendedLifetime(token) {}
    }

    @Test func givenRefreshWork_whenCalled_thenTheTaskListRefreshes() async {
        // given
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willReturn()
        let sut = MenuBarViewRepository(taskListRepository: taskList)

        // when
        await sut.refreshWork()

        // then
        verify(taskList).refresh().called(1)
    }

    @Test func givenAcquireEventLease_whenCalled_thenItPassesThroughToEventStreamRepository() {
        // given
        let eventStream = MockEventStreamRepository()
        let lease = MockEventStreamLease()
        given(eventStream).acquire(.value("abc123")).willReturn(lease)
        let sut = MenuBarViewRepository(eventStreamRepository: eventStream)
        
        // when
        let result = sut.acquireEventLease("abc123")
        
        // then
        #expect(result === lease)
    }
    
    @Test func givenCurrent_whenCalled_thenItPassesThroughToEventStreamRepository() {
        // given — `TimelineItem` has no public initializer, built via the public `TaskEvent(line:)`
        // decoder and `Timeline.items(from:)`.
        let eventStream = MockEventStreamRepository()
        let event = TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":0,"task_id":"t1","kind":"assistant_text","text":"hi"}"#)!
        let item = Timeline.items(from: [event])[0]
        given(eventStream).current(for: .value("abc123")).willReturn(item)
        let sut = MenuBarViewRepository(eventStreamRepository: eventStream)

        // then
        #expect(sut.current("abc123") == item)
    }
}
