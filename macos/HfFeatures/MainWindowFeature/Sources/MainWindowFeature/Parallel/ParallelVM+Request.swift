//
//  ParallelVM+Request.swift
//  MainWindowFeature
//
//  View prompt: while it is on, every resident lane reads its conversation's stored first request through the engine
//  and shows it above the feed. A read starts only for a leased prompt task whose request was never read in that
//  lease's generation; the result is stored per task and applied when columns publish (like message notes), not
//  through `captureInput`.
//

import Combine
import Foundation
import HfRepository

// MARK: - Request reads

extension ParallelVM {
    /// The bound of a lane's first read; "Read more" raises it to the engine's 128 KiB view limit.
    static let initialRequestBytes = 65536
    static let maximumRequestBytes = 131_072

    /// The task whose stored request a lane shows: the conversation's first member.
    func promptTaskID(of conversationID: String) -> String? { conversationByID[conversationID]?.first.taskID }

    /// Starts or stops request reads to match View prompt, residency and leases. Idempotent.
    func syncRequestReads() {
        let wanted: Set<String> = showPrompt && !isWorkflowInspector
            ? Set(orderedConversations.filter { residentIDs.contains($0.id) }.map(\.first.taskID).filter { leaseGenerations[$0] != nil })
            : []
        for id in Set(requestSubscriptions.keys).subtracting(wanted) { requestSubscriptions[id]?.cancel(); requestSubscriptions[id] = nil }
        for id in wanted where requestSubscriptions[id] == nil { startRequestRead(id) }
    }

    private func startRequestRead(_ taskID: String) {
        guard let generation = leaseGenerations[taskID] else { return }
        requestStates[taskID] = useCase.requestState(for: taskID)
        let epochAtStart = epoch
        requestSubscriptions[taskID] = useCase.requestPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, didSubscribe, epoch == epochAtStart, leaseGenerations[taskID] == generation,
                      useCase.requestState(for: taskID) == state, requestStates[taskID] != state else { return }
                requestStates[taskID] = state
                publishColumns()
            }
        // One read per lease generation, and only for a request nobody has read yet.
        if requestStates[taskID] == .notRequested, requestReadGenerations[taskID] != generation {
            requestReadGenerations[taskID] = generation
            useCase.readRequest(for: taskID, maxBytes: Self.initialRequestBytes)
        }
    }

    /// Drops a released lease's request state, so nothing is kept without a lease.
    func releaseRequest(_ taskID: String) {
        requestSubscriptions[taskID]?.cancel()
        requestSubscriptions[taskID] = nil
        requestStates[taskID] = nil
        requestReadGenerations[taskID] = nil
    }

    func cancelRequestReads() {
        for subscription in requestSubscriptions.values { subscription.cancel() }
        requestSubscriptions.removeAll()
        requestStates.removeAll()
        requestReadGenerations.removeAll()
    }

    func didReadRequest(taskID: String, maxBytes: Int) {
        guard leaseGenerations[taskID] != nil, requestSubscriptions[taskID] != nil else { return }
        useCase.readRequest(for: taskID, maxBytes: min(Self.maximumRequestBytes, max(1, maxBytes)))
    }

    func didCopyRequest(_ text: String) { _ = routing.copyToPasteboard(text) }

    /// Applies the stored request to a lane's column while View prompt is on.
    func applyRequest(to column: inout ParallelColumnModel, conversationID: String) {
        guard showPrompt, !isWorkflowInspector, let taskID = promptTaskID(of: conversationID) else { return }
        column.request = requestStates[taskID]
        guard column.request != nil else { return }
        column.onReadRequest = { [weak self] bytes in self?.didReadRequest(taskID: taskID, maxBytes: bytes) }
        column.onCopyRequest = { [weak self] text in self?.didCopyRequest(text) }
    }
}

// MARK: - Column UI state

extension ParallelVM {
    /// The lane's UI state, created on first use and kept while the conversation is a member; its announced-outcome
    /// memory is the VM's, so it survives the state being discarded.
    func columnState(for id: String) -> ParallelColumnUIState {
        if let state = uiStates[id] { return state }
        let state = ParallelColumnUIState(outcomeMemory: outcomeMemory, key: id)
        if conversationByID[id] != nil { uiStates[id] = state }
        return state
    }
}
