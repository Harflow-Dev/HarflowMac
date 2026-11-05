import Combine
import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import os

// MARK: - PublicEventFacadeHarness

struct PublicEventFacadeHarness: Sendable {
    let reader: ObservationScriptReader
    let prompts: FacadePromptReader
    let ticks: LockedBox<[@Sendable () -> Void]>
    let snapshots: MockTaskSnapshotRepository
    let repository: EventStreamRepositoryImpl

    init(delivery: @escaping PublicEventObservationSession.Delivery = { $0() },
         publicationDelivery: @escaping PublicEventObservationSession.Delivery = { DispatchQueue.main.async(execute: $0) }) {
        let reader = ObservationScriptReader()
        let prompts = FacadePromptReader()
        let ticks = LockedBox<[@Sendable () -> Void]>([])
        let snapshots = MockTaskSnapshotRepository()
        self.reader = reader
        self.prompts = prompts
        self.ticks = ticks
        self.snapshots = snapshots
        let scheduler = MockScheduling()
        given(scheduler).now().willReturn(Date())
        given(scheduler).schedule(after: .any, execute: .any).willReturn(AnyCancellable {})
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willProduce { _, callback in
            ticks.mutate { $0.append(callback) }
            return AnyCancellable {}
        }
        given(snapshots).refresh(.any).willReturn()
        self.repository = EventStreamRepositoryImpl(snapshotRepository: snapshots, scheduler: scheduler,
            reader: reader, promptRepository: prompts, delivery: delivery, publicationDelivery: publicationDelivery)
    }

    func tick() { ticks.value.forEach { $0() } }
}

// MARK: - FacadePromptReader

final class FacadePromptReader: TaskPromptRepository, Sendable {
    struct Request: Sendable {
        let maxBytes: Int
        let current: @Sendable () -> Bool
        let continuation: CheckedContinuation<Result<TaskPromptResult, ToolError>, Never>
    }

    private let state = OSAllocatedUnfairLock(initialState: [Request]())
    var requests: [Request] { state.withLock { $0 } }
    func read(taskID _: String, maxBytes: Int,
              operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskPromptResult, ToolError> {
        await withCheckedContinuation { continuation in
            state.withLock { $0.append(Request(maxBytes: maxBytes, current: operationIsCurrent, continuation: continuation)) }
        }
    }

    func finish(_ index: Int, _ result: Result<TaskPromptResult, ToolError>) { requests[index].continuation.resume(returning: result) }
}
