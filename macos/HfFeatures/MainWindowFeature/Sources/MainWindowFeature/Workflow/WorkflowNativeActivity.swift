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
    var error: String?
    var hasEarlierActivity = false
    /// Whether a fetch for this execution has succeeded; a settled execution is pulsed until one has.
    var loaded = false
}

// MARK: - WorkflowNativeActivityView

struct WorkflowNativeActivityView: View {
    let model: WorkflowNativeActivityModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                Text(model.title + " · Subagent").font(.hf(.body, weight: .semibold))
                Text(model.status).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                if model.limited { Text("Activity limited").font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                if let error = model.error { Text(error).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                if model.hasEarlierActivity { Text("Showing the latest 200 activity events.").font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                ForEach(model.items) { item in
                    TimelineRow(model: TimelineRowModel(item: item, start: nil, live: ["running", "launch_requested"].contains(model.status)))
                }
            }
.padding(HfRadius.Metrics.spacing16)
.frame(maxWidth: .infinity, alignment: .leading)
            // The user-authorized scrollbar amendment: this alternate feed bypasses
            // ActivityFeedView, so the shared thin, auto-hiding native chrome is attached to
            // its own enclosing vertical scroll view here — inside the document, exactly as
            // ActivityFeedView does, with no interaction or accessibility footprint and no
            // observer, paging or data change.
.background(ActivityScrollChrome())
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
            items: next.items, error: next.error, hasEarlierActivity: next.hasEarlierActivity, loaded: next.loaded)
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

    private func applyNativeActivity(items: [TimelineItem], more: Bool) {
        guard var next = nativeActivity else { return }
        next.items = items
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
                let items = await Task.detached(priority: .userInitiated) {
                    let events = (page["events"]?.arrayValue ?? []).compactMap { TaskEvent(line: $0.rendered()) }
                    return Timeline.items(from: events)
                }.value
                guard !Task.isCancelled, selectedRun?.id == runID, nativeActivity?.executionID == executionID else { return }
                applyNativeActivity(items: items, more: page["has_more"]?.boolValue ?? false)
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
