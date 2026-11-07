import Combine
import Foundation
import MonitorCore

// MARK: - PublicEventHolder

/// Mutable only under the facade lock. Envelopes fence already queued main-queue deliveries.
final class PublicEventHolder: @unchecked Sendable {
    struct FrameEnvelope { let generation: UUID; let frame: EventObservationFrame }
    struct RequestEnvelope { let generation: UUID; let state: TaskRequestReadState }
    let taskID: String
    var lifetime = UUID()
    var deliveryGeneration = UUID()
    var roles: [UUID: Bool] = [:]
    var lease: PublicEventObservationLease?
    var promptTask: Task<Void, Never>?
    var requestID = UUID()
    var readMoreUsed = false
    var frame: EventObservationFrame
    var request: TaskRequestReadState = .notRequested
    var publicationPending = false
    let frames: CurrentValueSubject<FrameEnvelope, Never>
    let requests: CurrentValueSubject<RequestEnvelope, Never>

    init(taskID: String) {
        self.taskID = taskID
        self.frame = Self.empty(taskID)
        self.frames = CurrentValueSubject(FrameEnvelope(generation: deliveryGeneration, frame: frame))
        self.requests = CurrentValueSubject(RequestEnvelope(generation: deliveryGeneration, state: .notRequested))
    }

    private static func empty(_ taskID: String) -> EventObservationFrame {
        EventObservationFrame(taskID: taskID, scope: EventObservationScope(sessionID: UUID(), sourceID: UUID(), windowID: UUID()))
    }

    func apply(_ next: EventObservationFrame) -> Bool {
        // Session revisions are transport bookkeeping, not rendered content.
        let comparable = EventObservationFrame(taskID: next.taskID, scope: next.scope, revision: frame.revision,
                                               records: next.records, events: next.events, items: next.items,
                                               history: next.history, summary: next.summary, logState: next.logState)
        guard comparable != frame else { return false }
        frame = next
        return true
    }

    func setRequest(_ next: TaskRequestReadState) -> Bool {
        guard request != next else { return false }
        request = next
        return true
    }

    func reset() {
        lifetime = UUID()
        deliveryGeneration = UUID()
        requestID = UUID()
        readMoreUsed = false
        promptTask?.cancel()
        promptTask = nil
        lease?.release()
        lease = nil
        frame = Self.empty(taskID)
        request = .notRequested
    }
}

// MARK: - PublicFacadeLease

final class PublicFacadeLease: EventStreamLease, @unchecked Sendable {
    let taskID: String
    private let lock = NSLock()
    private var body: (@Sendable () -> Void)?
    init(taskID: String, release: @escaping @Sendable () -> Void) { self.taskID = taskID; self.body = release }
    func release() {
        lock.lock()
        let release = body
        body = nil
        lock.unlock()
        release?()
    }

    deinit { release() }
}
