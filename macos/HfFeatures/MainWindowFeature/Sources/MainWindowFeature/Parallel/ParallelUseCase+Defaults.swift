//
//  ParallelUseCase+Defaults.swift
//  MainWindowFeature
//
//  Split out of ParallelVM.swift purely to keep that file under the swiftlint length budget —
//  same protocol, same behaviour. The default implementations that make history pagination an
//  optional part of the Parallel use-case contract.
//

import Combine
import Foundation
import HfRepository
import MonitorCore

// MARK: - ParallelUseCase

extension ParallelUseCase {
    func recoveredTranscript(for _: String) -> RecoveredTranscriptFrame { .init() }
    func recoveredTranscriptPublisher(for id: String) -> AnyPublisher<RecoveredTranscriptFrame, Never> {
        Just(recoveredTranscript(for: id)).eraseToAnyPublisher()
    }

    func observation(for id: String) -> EventObservationFrame {
        EventObservationFrame(taskID: id, scope: .init(sessionID: UUID(), sourceID: UUID(), windowID: UUID()))
    }

    func observationPublisher(for id: String) -> AnyPublisher<EventObservationFrame, Never> { Just(observation(for: id)).eraseToAnyPublisher() }
    @discardableResult func requestObservation(_: EventObservationAction, for _: String, scope _: EventObservationScope) -> Bool { false }

    func eventHistory(for _: String) -> EventHistoryState { EventHistoryState() }
    func eventHistoryPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { Just(eventHistory(for: id)).eraseToAnyPublisher() }
    @discardableResult func loadMoreEvents(_: String) -> Bool { false }
    func conversationHistory(sessionID _: String, cursor _: String?) async throws -> TaskHistoryPage? { nil }
}
