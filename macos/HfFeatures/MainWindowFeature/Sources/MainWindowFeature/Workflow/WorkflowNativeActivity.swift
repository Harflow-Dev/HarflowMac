import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowNativeActivityModel

/// Native execution activity has no process task or independent terminal handoff.
struct WorkflowNativeActivityModel: Equatable {
    let executionID: String
    let title: String
    let status: String
    let limited: Bool
    var items: [TimelineItem] = []
    var markdown: [Int: StreamingMarkdownState] = [:]
    var error: String?
    var hasEarlierActivity = false
    /// Whether a fetch for this execution has succeeded; a settled execution is pulsed until one has.
    var loaded = false
}

// MARK: - WorkflowNativeActivityView

struct WorkflowNativeActivityView: View {
    let model: WorkflowNativeActivityModel
    var messages: [WorkMessageBubble] = []
    var onCancel: ((String) -> Void)?
    var isCancelDisabled = false
    @State private var following = true
    @State private var actions = WorkflowActivityActions()

    var body: some View {
        WorkflowActivityNativeView(presentation: WorkflowActivityPresentation(model: model, messages: messages,
                                                                            isCancelDisabled: isCancelDisabled, hasCancel: onCancel != nil),
                                   actions: actions, onCancel: onCancel, onFollowing: { following = $0 })
            .overlay(alignment: .bottomTrailing) {
                let pinned = messages.filter(\.isPinned)
                if !following, !pinned.isEmpty {
                    QueuedMessageJump(count: pinned.count) { actions.jump() }
                }
            }
    }
}

// MARK: - WorkflowVM native activity

extension WorkflowVM {
    func updateActivityMembership() {
        scheduleRunSidebar()
    }

    func openOwnerTask(_ id: String) { routing.selectTask(id) }

    func selectActivation(_ id: String?) {
        selectedActivationID = id
        scheduleRunSidebar()
    }

    func updateNativeActivity() {
        nativeActivityTask?.cancel()
        nativeActivityTask = nil
        guard runGraphVisible, let run = selectedRun,
              let activation = runSidebar.activation,
              let executionID = activation["id"]?.stringValue,
              WorkflowExecutionPresentation(raw: activation).isSubagent else {
            if nativeActivity != nil { nativeActivity = nil }
            return
        }
        let projection = WorkflowExecutionPresentation(raw: activation)
        var next = nativeActivity?.executionID == executionID ? nativeActivity! : WorkflowNativeActivityModel(
            executionID: executionID, title: runSidebar.title, status: activation["status"]?.stringValue ?? "unknown",
            limited: projection.activityLimited)
        next = WorkflowNativeActivityModel(executionID: executionID, title: runSidebar.title,
            status: activation["status"]?.stringValue ?? "unknown", limited: projection.activityLimited,
            items: next.items, markdown: next.markdown, error: next.error, hasEarlierActivity: next.hasEarlierActivity, loaded: next.loaded)
        if nativeActivity != next { nativeActivity = next }
        nativeActivityTask = fetchNativeActivity(runID: run.id, executionID: executionID)
    }

    /// A poll that found the run document unchanged: a running subagent's activity feed still
    /// moves without the run document changing, so refetch it — but never recreate the model,
    /// cancel a fetch already in flight, or drop `hasEarlierActivity`. Nothing is assigned unless
    /// the fetched content differs, so an identical poll publishes nothing.
    func pulseNativeActivity() {
        // Relies on every cancel site (`updateNativeActivity`, `WorkflowVM.didDisappear`) setting
        // `nativeActivityTask` to nil; a stale non-nil task would block the pulse forever.
        guard runGraphVisible, nativeActivityTask == nil, let run = selectedRun, let current = nativeActivity,
              !current.loaded || ["running", "launch_requested"].contains(current.status) else { return }
        nativeActivityTask = fetchNativeActivity(runID: run.id, executionID: current.executionID)
    }

    private func applyNativeActivity(items: [TimelineItem], markdown: [Int: StreamingMarkdownState], more: Bool) {
        guard var next = nativeActivity else { return }
        next.items = items
        next.markdown = markdown
        next.hasEarlierActivity = more
        next.error = nil
        next.loaded = true
        if nativeActivity != next { nativeActivity = next }
    }

    private func fetchNativeActivity(runID: String, executionID: String) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { nativeActivityTask = nil } }
            do {
                let page = try await useCase.command("inspect", options: ["--view=activity", "--limit=200"], positionals: [runID, executionID])
                guard !Task.isCancelled, selectedRun?.id == runID, nativeActivity?.executionID == executionID else { return }
                let previous = nativeActivity?.markdown ?? [:]
                let prepared = await Task.detached(priority: .userInitiated) {
                    let events = (page["events"]?.arrayValue ?? []).compactMap { TaskEvent(line: $0.rendered()) }
                    let items = Timeline.items(from: events)
                    var markdown: [Int: StreamingMarkdownState] = [:]
                    for item in items {
                        if case .text(let text, let streaming) = item.body {
                            markdown[item.id] = (previous[item.id] ?? StreamingMarkdownState()).updating(text: text, isStreaming: streaming)
                        }
                    }
                    return (items, markdown)
                }.value
                guard !Task.isCancelled, selectedRun?.id == runID, nativeActivity?.executionID == executionID else { return }
                applyNativeActivity(items: prepared.0, markdown: prepared.1, more: page["has_more"]?.boolValue ?? false)
            } catch {
                guard !Task.isCancelled, selectedRun?.id == runID, nativeActivity?.executionID == executionID else { return }
                let message = "Unable to load subagent activity. " + Self.message(error)
                if nativeActivity?.error != message { nativeActivity?.error = message }
            }
        }
    }
}

#if DEBUG
private struct WorkflowNativeActivityPreview: View {
    var body: some View {
        WorkflowNativeActivityView(model: .init(
            executionID: "example",
            title: "Review",
            status: "running",
            limited: true,
            error: "Showing the latest 200 activity events.",
            hasEarlierActivity: true
        ))
        .background(Color.cardFill)
    }
}

#Preview("Native subagent activity - light") {
    WorkflowNativeActivityPreview()
        .frame(width: HfRadius.Metrics.workflowPreviewHeight,
                height: HfRadius.Metrics.activityPreviewWidth)
        .preferredColorScheme(.light)
}

#Preview("Native subagent activity - dark") {
    WorkflowNativeActivityPreview()
        .frame(width: HfRadius.Metrics.workflowPreviewHeight,
                height: HfRadius.Metrics.activityPreviewWidth)
        .preferredColorScheme(.dark)
}

#Preview("Native subagent activity - narrow") {
    WorkflowNativeActivityPreview()
        .frame(width: HfRadius.Metrics.activityPreviewWidth,
                height: HfRadius.Metrics.activityPreviewWidth)
        .preferredColorScheme(.light)
}
#endif
