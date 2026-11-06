import HfRepository
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
    var settled: Bool?
    var activityState: String?
    var runID: String?
}

/// Captured public input identity for a single activity read.
struct WorkflowNativeActivityRequest: Equatable {
    let runID: String
    let executionID: String
    let activation: [String: JSONValue]?
    let intent: WorkflowActivityReadIntent
    let runtime: QualificationRuntimeToken?
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
        guard runGraphVisible, let run = selectedRun,
              let activation = runSidebar.activation,
              let executionID = activation["id"]?.stringValue,
              WorkflowExecutionPresentation(raw: activation).isSubagent else {
            nativeActivityRequestID = UUID()
            nativeActivityTask?.cancel()
            nativeActivityTask = nil
            if nativeActivity != nil { nativeActivity = nil }
            return
        }
        let runtime = try? useCase.activityRuntime()
        let desired = WorkflowNativeActivityRequest(runID: run.id, executionID: executionID, activation: activation,
                                                   intent: activityIntent(runtime: runtime), runtime: runtime)
        if nativeActivityTask != nil, nativeActivityRequest == desired { return }
        nativeActivityRequestID = UUID()
        nativeActivityTask?.cancel()
        nativeActivityTask = nil
        let projection = WorkflowExecutionPresentation(raw: activation)
        var next = nativeActivity?.executionID == executionID && nativeActivity?.runID == run.id ? nativeActivity! : WorkflowNativeActivityModel(
            executionID: executionID, title: runSidebar.title, status: activation["status"]?.stringValue ?? "unknown",
            limited: projection.activityLimited)
        next = WorkflowNativeActivityModel(executionID: executionID, title: runSidebar.title,
            status: activation["status"]?.stringValue ?? "unknown", limited: projection.activityLimited,
            items: next.items, markdown: next.markdown, error: next.error, hasEarlierActivity: next.hasEarlierActivity,
            loaded: next.loaded, settled: next.settled,
            activityState: next.activityState, runID: run.id)
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
              !current.loaded || currentActivityIntent != .settledOnly else { return }
        nativeActivityTask = fetchNativeActivity(runID: run.id, executionID: current.executionID)
    }

    private func applyNativeActivity(items: [TimelineItem], markdown: [Int: StreamingMarkdownState], page: WorkflowActivityPage) {
        guard var next = nativeActivity else { return }
        next.items = items
        next.markdown = markdown
        next.hasEarlierActivity = page.hasMore
        next.settled = page.settled
        next.activityState = page.activityState
        next.error = nil
        next.loaded = true
        if nativeActivity != next { nativeActivity = next }
    }

    private var currentActivityIntent: WorkflowActivityReadIntent {
        guard let run = selectedRun, let activation = runSidebar.activation else { return .allowUnsettled }
        return runPolling.activityIntent(runID: run.id, activation: activation, runtime: try? useCase.activityRuntime())
    }

    private func activityIntent(runtime: QualificationRuntimeToken?) -> WorkflowActivityReadIntent {
        guard let run = selectedRun, let activation = runSidebar.activation else { return .allowUnsettled }
        return runPolling.activityIntent(runID: run.id, activation: activation, runtime: runtime)
    }

    private func applyUnavailableNativeActivity(_ page: WorkflowActivityPage) -> Bool {
        guard page.activityState == "unavailable" else { return false }
        if nativeActivity?.activityState != page.activityState { nativeActivity?.activityState = page.activityState }
        if nativeActivity?.settled != page.settled { nativeActivity?.settled = page.settled }
        let message = "Subagent activity is unavailable."
        if nativeActivity?.error != message { nativeActivity?.error = message }
        return true
    }

    private func applyNativeActivityFailure(_ error: Error, capturedRuntime: Result<QualificationRuntimeToken, Error>) {
        if case .success(let runtime) = capturedRuntime, (try? useCase.activityRuntime()) != runtime { return }
        let message = "Unable to load subagent activity. " + Self.message(error)
        if nativeActivity?.error != message { nativeActivity?.error = message }
    }

    private func fetchNativeActivity(runID: String, executionID: String) -> Task<Void, Never> {
        let requestID = UUID()
        nativeActivityRequestID = requestID
        let capturedRuntime = Result { try useCase.activityRuntime() }
        let runtime = try? capturedRuntime.get()
        let intent = activityIntent(runtime: runtime)
        let activation = runSidebar.activation
        nativeActivityRequest = WorkflowNativeActivityRequest(runID: runID, executionID: executionID, activation: activation,
                                                              intent: intent, runtime: runtime)
        return Task { [weak self] in
            guard let self else { return }
            defer { if nativeActivityRequestID == requestID { nativeActivityTask = nil } }
            do {
                let runtime = try capturedRuntime.get()
                let page = try await useCase.activity(runID: runID, executionID: executionID, intent: intent, runtime: runtime)
                guard !Task.isCancelled, nativeActivityRequestID == requestID, runGraphVisible,
                      selectedRun?.id == runID, nativeActivity?.executionID == executionID,
                      runSidebar.activation == activation, currentActivityIntent == intent, (try? useCase.activityRuntime()) == runtime else { return }
                guard intent != .settledOnly || page.settled != false else {
                    throw ToolError.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Unsettled workflow activity response")
                }
                if applyUnavailableNativeActivity(page) { return }
                let previous = nativeActivity?.markdown ?? [:]
                let prepared = await Task.detached(priority: .userInitiated) {
                    let events = page.events
                    let items = Timeline.items(from: events)
                    var markdown: [Int: StreamingMarkdownState] = [:]
                    for item in items {
                        if case .text(let text, let streaming) = item.body {
                            markdown[item.id] = (previous[item.id] ?? StreamingMarkdownState()).updating(text: text, isStreaming: streaming)
                        }
                    }
                    return (items, markdown)
                }.value
                guard !Task.isCancelled, nativeActivityRequestID == requestID, runGraphVisible,
                      selectedRun?.id == runID, nativeActivity?.executionID == executionID,
                      runSidebar.activation == activation, currentActivityIntent == intent, (try? useCase.activityRuntime()) == runtime else { return }
                applyNativeActivity(items: prepared.0, markdown: prepared.1, page: page)
            } catch {
                guard !Task.isCancelled, nativeActivityRequestID == requestID, runGraphVisible,
                      selectedRun?.id == runID, nativeActivity?.executionID == executionID,
                      runSidebar.activation == activation, currentActivityIntent == intent else { return }
                applyNativeActivityFailure(error, capturedRuntime: capturedRuntime)
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
