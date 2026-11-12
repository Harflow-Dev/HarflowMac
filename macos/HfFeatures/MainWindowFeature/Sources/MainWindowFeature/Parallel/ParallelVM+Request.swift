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

// MARK: - ParallelRequestStore

/// What View prompt holds per prompt task: the stored request (absent until a read started), its subscription, the lease
/// generation it was read in and the last copy's feedback line.
@MainActor
final class ParallelRequestStore {
    var states: [String: TaskRequestReadState] = [:]
    var subscriptions: [String: AnyCancellable] = [:]
    var generations: [String: UUID] = [:]
    var feedback: [String: String] = [:]

    func remove(_ taskID: String) {
        subscriptions[taskID]?.cancel()
        subscriptions[taskID] = nil
        states[taskID] = nil
        generations[taskID] = nil
        feedback[taskID] = nil
    }

    func removeAll() {
        for subscription in subscriptions.values { subscription.cancel() }
        subscriptions.removeAll()
        states.removeAll()
        generations.removeAll()
        feedback.removeAll()
    }
}

// MARK: - Request reads

extension ParallelVM {
    var requestStates: [String: TaskRequestReadState] { get { requests.states } set { requests.states = newValue } }
    var requestSubscriptions: [String: AnyCancellable] { get { requests.subscriptions } set { requests.subscriptions = newValue } }
    var requestReadGenerations: [String: UUID] { get { requests.generations } set { requests.generations = newValue } }

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
        for id in Set(requestSubscriptions.keys).subtracting(wanted) {
            requestSubscriptions[id]?.cancel()
            requestSubscriptions[id] = nil
            requests.feedback[id] = nil
        }
        for id in wanted where requestSubscriptions[id] == nil { startRequestRead(id) }
    }

    private func startRequestRead(_ taskID: String) {
        guard let generation = leaseGenerations[taskID] else { return }
        // A request nobody has asked for is simply absent, so the first thing a lane shows is the read's own "loading".
        let initial = useCase.requestState(for: taskID)
        requests.states[taskID] = initial == .notRequested ? nil : initial
        let epochAtStart = epoch
        requests.subscriptions[taskID] = useCase.requestPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, didSubscribe, epoch == epochAtStart, leaseGenerations[taskID] == generation,
                      useCase.requestState(for: taskID) == state else { return }
                let value: TaskRequestReadState? = state == .notRequested ? nil : state
                guard requests.states[taskID] != value else { return }
                requests.states[taskID] = value
                publishColumns()
            }
        // One read per lease generation, and only for a request nobody has read yet.
        if requests.states[taskID] == nil, requests.generations[taskID] != generation {
            requests.generations[taskID] = generation
            useCase.readRequest(for: taskID, maxBytes: Self.initialRequestBytes)
        }
    }

    /// Drops a released lease's request state, so nothing is kept without a lease.
    func releaseRequest(_ taskID: String) { requests.remove(taskID) }

    func cancelRequestReads() { requests.removeAll() }

    func didReadRequest(taskID: String, maxBytes: Int) {
        guard leaseGenerations[taskID] != nil, requestSubscriptions[taskID] != nil else { return }
        useCase.readRequest(for: taskID, maxBytes: min(Self.maximumRequestBytes, max(1, maxBytes)))
    }

    /// Copies the request and says how it went, as the task screen does, so a failed copy is not silent.
    func didCopyRequest(_ text: String, taskID: String) {
        requests.feedback[taskID] = routing.copyToPasteboard(text) ? "Copied" : "Select the displayed text and use your system copy command to copy it."
        publishColumns()
    }

    /// Applies the stored request to a lane's column while View prompt is on.
    func applyRequest(to column: inout ParallelColumnModel, conversationID: String) {
        guard showPrompt, !isWorkflowInspector, let taskID = promptTaskID(of: conversationID) else { return }
        column.request = requestStates[taskID]
        guard column.request != nil else { return }
        column.onReadRequest = { [weak self] bytes in self?.didReadRequest(taskID: taskID, maxBytes: bytes) }
        column.onCopyRequest = { [weak self] text in self?.didCopyRequest(text, taskID: taskID) }
        column.requestFeedback = requests.feedback[taskID]
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
