import Combine
import Foundation
import HfRepository

// MARK: - TaskDetailUseCase observation defaults

extension TaskDetailUseCase {
    func requestState(for _: String) -> TaskRequestReadState { .notRequested }
    func requestPublisher(for id: String) -> AnyPublisher<TaskRequestReadState, Never> { Just(requestState(for: id)).eraseToAnyPublisher() }
    func readRequest(for _: String, maxBytes _: Int) {}
    func recoveredTranscript(for _: String) -> RecoveredTranscriptFrame { .init() }
    func recoveredTranscriptPublisher(for id: String) -> AnyPublisher<RecoveredTranscriptFrame, Never> {
        Just(recoveredTranscript(for: id)).eraseToAnyPublisher()
    }

    func observation(for id: String) -> EventObservationFrame {
        EventObservationFrame(taskID: id, scope: .init(sessionID: UUID(), sourceID: UUID(), windowID: UUID()))
    }

    func observationPublisher(for id: String) -> AnyPublisher<EventObservationFrame, Never> { Just(observation(for: id)).eraseToAnyPublisher() }
    @discardableResult func requestObservation(_: EventObservationAction, for _: String, scope _: EventObservationScope) -> Bool { false }

}
