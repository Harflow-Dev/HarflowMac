import Foundation
import HfRepository
import MonitorCore

// MARK: - ParallelModelLabelStore

/// The engine's model labels for the lanes' captions and the bookkeeping of their requests. Main actor only.
@MainActor final class ParallelModelLabelStore {
    /// Backend, then option value, to label. Kept for the life of this view model (a new group selection builds a fresh one; the
    /// repository's per-backend cache is what persists across opens); written only on change.
    var labels: [String: [String: String]] = [:]
    /// Backends whose model list this appearance already asked for (an empty answer is not retried until the next appearance).
    var requested: Set<String> = []
    var requests: [String: Task<Void, Never>] = [:]
    /// Test seam: answers a request instead of the use case.
    var loader: (@Sendable (String) async -> [ModelOption])?
}

// MARK: - Lane model labels

extension ParallelVM {
    /// The conversation's current member merged with its snapshot: the one task the caption and the label request read.
    func mergedCurrent(of conversation: Conversation) -> TaskInfo {
        WorkflowNodePresentation.merged(latestSnapshots[conversation.current.taskID], with: conversation.current)
    }

    /// `presentation` with the caption the descriptor holds now, so a build that commits after a label arrived cannot bring back
    /// the caption it was captured with.
    func withCurrentCaption(_ presentation: ParallelColumnPresentation) -> ParallelColumnPresentation {
        guard let caption = descriptors[presentation.id]?.caption, caption != presentation.caption else { return presentation }
        var patched = presentation
        patched.caption = caption
        return patched
    }

    /// The lane caption for `current`: harness, the engine's label for its model (else the raw id) and "taken over".
    func caption(for current: TaskInfo) -> String {
        let label = ParallelLaneStatus.modelLabel(model: current.model, labels: modelLabels.labels[current.backend])
        return ParallelLaneStatus.caption(current: current, modelLabel: label)
    }

    /// Asks the engine for the models of every member backend not yet asked for in this appearance. One request per backend
    /// per appearance: an empty answer is not retried until the next appearance or until a new backend joins. The Graph
    /// inspector does not draw the caption, so it never asks.
    func requestModelLabels() {
        guard didSubscribe, !isWorkflowInspector else { return }
        let backends = Set(orderedConversations.map { mergedCurrent(of: $0).backend }.filter { !$0.isEmpty })
        for backend in backends.subtracting(modelLabels.requested).sorted() {
            modelLabels.requested.insert(backend)
            let generation = epoch
            let useCase = useCase
            let loader = modelLabels.loader
            modelLabels.requests[backend] = Task { [weak self] in
                let options = if let loader { await loader(backend) } else { await useCase.modelOptions(backend: backend) }
                guard let self, didSubscribe, epoch == generation, !Task.isCancelled else { return }
                modelLabels.requests[backend] = nil
                applyModelLabels(options, backend: backend)
            }
        }
    }

    /// Stops in-flight requests and forgets what this appearance asked for; the labels already loaded are kept.
    func cancelModelLabelRequests() {
        for request in modelLabels.requests.values { request.cancel() }
        modelLabels.requests.removeAll()
        modelLabels.requested.removeAll()
    }

    /// Stores a non-empty answer and, when it changed what any lane's caption says, patches the cached descriptors and
    /// presentations (main actor, captions only: no residency or scheduling rerun) and publishes the columns once.
    func applyModelLabels(_ options: [ModelOption], backend: String) {
        guard !options.isEmpty else { return }
        let labels = Dictionary(options.map { ($0.value, $0.label) }, uniquingKeysWith: { first, _ in first })
        guard modelLabels.labels[backend] != labels else { return }
        modelLabels.labels[backend] = labels
        refreshCaptions()
    }

    /// Patches the caption only: the descriptors the columns are drawn from, and the cached presentations and inputs for
    /// consistency. No build input depends on it, so nothing is rescheduled and an in-flight build is left alone.
    private func refreshCaptions() {
        var changed = false
        for conversation in orderedConversations {
            let id = conversation.id
            let text = caption(for: mergedCurrent(of: conversation))
            if descriptors[id]?.caption != text { descriptors[id]?.caption = text; changed = true }
            if presentations[id]?.caption != text { presentations[id]?.caption = text; changed = true }
            if completedInputs[id]?.base.caption != text { completedInputs[id]?.base.caption = text }
            if desiredInputs[id]?.base.caption != text { desiredInputs[id]?.base.caption = text }
        }
        if changed { publishColumns() }
    }
}
