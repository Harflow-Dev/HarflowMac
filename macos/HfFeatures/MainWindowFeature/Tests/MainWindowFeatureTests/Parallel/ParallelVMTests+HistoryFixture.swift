import Combine
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore

extension ParallelVMTests {
    private func configureObservation(_ harness: SUT) {
        let useCase = harness.useCase
        let eventsBox = harness.eventsBox
        let historyBox = harness.historyBox
        let historySubjectsBox = harness.historySubjectsBox
        given(useCase).recoveredTranscript(for: .any).willReturn(.init())
        given(useCase).recoveredTranscriptPublisher(for: .any).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).observation(for: .any).willProduce { id in
            if let frame = harness.observationBox.value[id] { return frame }
            return FeatureObservationFixture.frame(id: id, events: eventsBox.value[id] ?? [],
                items: harness.itemsBox.value[id] ?? [], availability: harness.availabilityBox.value[id] ?? .loading,
                history: historyBox.value[id] ?? .init())
        }
        given(useCase).observationPublisher(for: .any).willProduce { id in
            let itemSubject = harness.itemSubjectsBox.value[id]
            let items = itemSubject?.eraseToAnyPublisher()
                ?? Just(harness.itemsBox.value[id] ?? []).eraseToAnyPublisher()
            let history = historySubjectsBox.value[id]
                ?? CurrentValueSubject<EventHistoryState, Never>(historyBox.value[id] ?? .init())
            historySubjectsBox.value[id] = history
            let itemFrames = items.map { value in
                if harness.itemSubjectsBox.value[id] === itemSubject {
                    harness.itemsBox.value[id] = value
                    if !value.isEmpty { harness.availabilityBox.value[id] = .available }
                    return useCase.observation(for: id)
                }
                return FeatureObservationFixture.frame(id: id, events: eventsBox.value[id] ?? [], items: value,
                    availability: .available, history: historyBox.value[id] ?? .init())
            }
            let historyFrames = history.map { value in
                historyBox.value[id] = value
                return useCase.observation(for: id)
            }
            return Publishers.Merge(itemFrames, historyFrames).eraseToAnyPublisher()
        }
    }

    func configureHistory(_ harness: SUT, leasePool: ParallelTestLeasePool?) {
        stubRequests(harness)
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
        configureObservation(harness)
        given(useCase).requestObservation(.any, for: .any, scope: .any).willProduce { action, id, scope in
            guard scope == useCase.observation(for: id).scope else { return false }
            if action == .rebaseWindow {
                return useCase.observation(for: id).history.availableActions.contains(.rebaseWindow) && loadAdmissionBox.value
            }
            guard action == .loadEarlier else { return false }
            return useCase.loadMoreEvents(id)
        }
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
