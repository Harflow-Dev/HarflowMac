import Combine
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTestUtilities

extension ParallelVMTests {
    func configureHistory(_ harness: SUT, leasePool: ParallelTestLeasePool?) {
        let useCase = harness.useCase
        let eventsBox = harness.eventsBox
        let historyBox = harness.historyBox
        let historySubjectsBox = harness.historySubjectsBox
        let loadCallsBox = harness.loadCallsBox
        let loadAdmissionBox = harness.loadAdmissionBox
        let acquireEffectBox = harness.acquireEffectBox
        let releasedBox = harness.releasedBox
        let leasesBox = harness.leasesBox
        let conversationPagesBox = harness.conversationPagesBox
        given(useCase).conversationHistory(sessionID: .any, cursor: .any).willProduce { _, _ in
            conversationPagesBox.value.isEmpty ? nil : conversationPagesBox.value.removeFirst()
        }
        given(useCase).events(for: .any).willProduce { eventsBox.value[$0] ?? [] }
        given(useCase).eventHistory(for: .any).willProduce { historyBox.value[$0] ?? EventHistoryState() }
        given(useCase).eventHistoryPublisher(for: .any).willProduce { id in
            let subject = CurrentValueSubject<EventHistoryState, Never>(historyBox.value[id] ?? EventHistoryState())
            historySubjectsBox.value[id] = subject
            return subject.eraseToAnyPublisher()
        }
        given(useCase).loadMoreEvents(.any).willProduce { id in
            guard loadAdmissionBox.value else { return false }
            loadCallsBox.value.append(id)
            var history = historyBox.value[id] ?? EventHistoryState()
            history.isLoading = true
            historyBox.value[id] = history
            historySubjectsBox.value[id]?.send(history)
            return true
        }
        given(useCase).acquireEventLease(.any).willProduce { id in
            acquireEffectBox.value?(id)
            let lease = MockEventStreamLease()
            let token = leasePool?.acquire(id)
            given(lease).taskID.willReturn(id)
            given(lease).release().willProduce {
                releasedBox.value.insert(id)
                if let token { leasePool?.release(token) }
            }
            leasesBox.value[id] = lease
            return lease
        }
    }
}
