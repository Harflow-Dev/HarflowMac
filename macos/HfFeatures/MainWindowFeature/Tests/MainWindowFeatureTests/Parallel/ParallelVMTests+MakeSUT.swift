import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore

extension ParallelVMTests {
    func makeSUT(groupName: String = "g1", leasePool: ParallelTestLeasePool? = nil, publishesTopBar: Bool = false,
                 buildColumns: @escaping ParallelColumnsBuild = ParallelPresentationBuilder.buildColumns,
                 tasksPublisher: AnyPublisher<[TaskInfo], Never>? = nil) -> SUT {
        let useCase = MockParallelUseCase()
        let routing = MockParallelRouting()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let snapshotsSubject = PassthroughSubject<[String: TaskInfo], Never>()
        let busySubject = PassthroughSubject<Set<String>, Never>()
        let outcomesSubject = PassthroughSubject<[String: String], Never>()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let tasksBox = Box<[String: TaskInfo]>([:])
        let titlesBox = Box<[String: String]>([:])
        let itemsBox = Box<[String: [TimelineItem]]>([:])
        let itemSubjectsBox = Box<[String: PassthroughSubject<[TimelineItem], Never>]>([:])
        let availabilityBox = Box<[String: EventAvailability]>([:])
        let leasesBox = Box<[String: MockEventStreamLease]>([:])
        let releasedBox = Box<Set<String>>([])
        let runningInSubtreesBox = Box<[String]?>(nil)
        let observationBox = Box<[String: EventObservationFrame]>([:])
        let eventsBox = Box<[String: [TaskEvent]]>([:])
        let historyBox = Box<[String: EventHistoryState]>([:])
        let historySubjectsBox = Box<[String: CurrentValueSubject<EventHistoryState, Never>]>([:])
        let loadCallsBox = Box<[String]>([])
        let loadAdmissionBox = Box(true)
        let acquireEffectBox = Box<((String) -> Void)?>(nil)
        let conversationPagesBox = Box<[TaskHistoryPage?]>([])
        given(useCase).tasksPublisher().willReturn(tasksPublisher ?? tasksSubject.eraseToAnyPublisher())
        given(useCase).snapshotsPublisher().willReturn(snapshotsSubject.eraseToAnyPublisher())
        given(useCase).busyPublisher().willReturn(busySubject.eraseToAnyPublisher())
        given(useCase).outcomesPublisher().willReturn(outcomesSubject.eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        given(useCase).task(.any).willProduce { tasksBox.value[$0] }
        given(useCase).title(.any).willProduce { titlesBox.value[$0] ?? "Task \($0.prefix(8))" }
        given(useCase).items(for: .any).willProduce { itemsBox.value[$0] ?? [] }
        given(useCase).itemsPublisher(for: .any).willProduce { id in
            if let subject = itemSubjectsBox.value[id] { return subject.eraseToAnyPublisher() }
            return Just(itemsBox.value[id] ?? []).eraseToAnyPublisher()
        }
        given(useCase).prompt(for: .any).willReturn(nil)
        given(useCase).eventsAvailability(for: .any).willProduce { availabilityBox.value[$0] ?? .loading }
        given(useCase).eventsAvailabilityPublisher(for: .any).willProduce { id in
            Just(availabilityBox.value[id] ?? .loading).eraseToAnyPublisher()
        }
        given(useCase).runningInSubtrees(of: .any).willProduce { ids in runningInSubtreesBox.value ?? ids }
        given(useCase).cancelAll(.any).willReturn()
        given(useCase).beginTakeover(taskID: .any).willReturn()
        given(useCase).setOutcome(.any, .any).willReturn()
        given(routing).selectTask(.any).willReturn()
        Self.stubTopBar(routing)
        let sut = ParallelVM(groupName: groupName, useCase: useCase, routing: routing, publishesTopBar: publishesTopBar, buildColumns: buildColumns)
        sut.updateViewport(offset: 0, width: 100_000)
        let harness = SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: tasksSubject, snapshotsSubject: snapshotsSubject,
            busySubject: busySubject, outcomesSubject: outcomesSubject, titlesSubject: titlesSubject,
            tasksBox: tasksBox, titlesBox: titlesBox, itemsBox: itemsBox, itemSubjectsBox: itemSubjectsBox, availabilityBox: availabilityBox,
            leasesBox: leasesBox, releasedBox: releasedBox, runningInSubtreesBox: runningInSubtreesBox,
            observationBox: observationBox, eventsBox: eventsBox, historyBox: historyBox, historySubjectsBox: historySubjectsBox,
            loadCallsBox: loadCallsBox, loadAdmissionBox: loadAdmissionBox, acquireEffectBox: acquireEffectBox, conversationPagesBox: conversationPagesBox,
            requests: RequestStub()
        )
        Self.stubCatalog(useCase, harness.catalog)
        configureHistory(harness, leasePool: leasePool)
        return harness
    }

    // MARK: - Fresh listing entry (F4-40)

}
