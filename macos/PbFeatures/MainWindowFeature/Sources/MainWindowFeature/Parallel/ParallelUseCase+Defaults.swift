//
//  ParallelUseCase+Defaults.swift
//  MainWindowFeature
//
//  Split out of ParallelVM.swift purely to keep that file under the swiftlint length budget —
//  same protocol, same behaviour. The default implementations that make history pagination an
//  optional part of the Parallel use-case contract.
//

import Combine
import MonitorCore

// MARK: - ParallelUseCase

extension ParallelUseCase {
    func eventHistory(for _: String) -> EventHistoryState { EventHistoryState() }
    func eventHistoryPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { Just(eventHistory(for: id)).eraseToAnyPublisher() }
    @discardableResult func loadMoreEvents(_: String) -> Bool { false }
    func conversationHistory(sessionID _: String, cursor _: String?) async throws -> TaskHistoryPage? { nil }
}
