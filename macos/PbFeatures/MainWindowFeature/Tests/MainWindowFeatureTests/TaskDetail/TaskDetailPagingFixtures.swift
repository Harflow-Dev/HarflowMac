import Combine
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository

@MainActor
extension MockTaskDetailUseCase {
    func configurePagingDefaults(eventHistory: @escaping (String) -> EventHistoryState = { _ in EventHistoryState() }) {
        given(self).resolveTask(.any).willReturn(nil)
        given(self).conversationHistory(sessionID: .any, cursor: .any).willReturn(nil)
        given(self).eventHistory(for: .any).willProduce(eventHistory)
        given(self).eventHistoryPublisher(for: .any).willReturn(Empty().eraseToAnyPublisher())
        given(self).eventSummary(for: .any).willProduce { [weak self] id in
            var builder = EventSummaryBuilder()
            builder.append(self?.events(for: id) ?? [])
            builder.setAvailability(self?.eventsAvailability(for: id) ?? .loading)
            return builder.summary
        }
        given(self).eventSummaryPublisher(for: .any).willReturn(Empty().eraseToAnyPublisher())
        given(self).acquireSummaryLease(.any).willProduce { id in
            let lease = MockEventStreamLease()
            given(lease).taskID.willReturn(id)
            given(lease).release().willReturn()
            return lease
        }
    }
}
