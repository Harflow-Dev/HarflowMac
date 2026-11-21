import AppKit
import HfCommon
import HfRepository
import HfUI
import MonitorCore
import SwiftEnvironment
import SwiftUI

// MARK: - WorkflowSelectedSidebar

/// Selection activity uses the same retained feed state, paging and viewport leases as Parallel.
struct WorkflowSelectedSidebar<VM: WorkflowViewModel>: View {
    var viewModel: VM
    @Environment(\.viewEvent) private var viewEvent

    @State private var inlineApprovalController: CallerApprovalController?
    @State private var inlineApprovalTaskID: String?
    @State private var rootApprovalController: CallerApprovalController?
    @State private var rootApprovalRunID: String?
    @Environment(\.callerApprovalUseCaseOverride) private var approvalUseCaseOverride
    @GlobalEnvironment(\.toolEnvironmentRepository) private var approvalEnvironment
    @GlobalEnvironment(\.approvalResponseOwner) private var approvalResponseOwner
    @State private var callReveal: WorkflowInspectorCallReveal?
    @State private var consumedCallFocus: UUID?
    @State private var paneHeight: CGFloat = 0
    /// Measured chrome kept out of the feed's floor: the head block, the fallback composer and the inspector column's own chrome.
    @State private var headBlockHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    @State private var columnChrome = WorkflowLayoutHeights()
    /// The natural height of a caller approval awaiting a decision in the inspector column (0 when none).
    @State private var approvalDemand: CGFloat = 0
    @State private var approvalDecisionMinimum: CGFloat = 0
    @State private var steeringFooterHeight = WorkflowLayoutHeights()

    var body: some View {
        let state = viewModel.runSidebar
        let inspectorOwnsApproval = inspectorOwnsApproval(state)
        let fallback = viewModel.steeringOwnsComposer && !inspectorOwnsApproval
        let suppressPlaceholder = usesSteeringTranscript && viewModel.selectedActivity != nil && !hasSelectedInspector(state)
        let hasDetails = viewModel.selectedActivity.map { unavailableDetails(state, $0) != nil } ?? false
        let hasActivity = viewModel.nativeActivity != nil || state.childRunID != nil
            || (viewModel.selectedActivity != nil && (!suppressPlaceholder || hasDetails))
        let steeringAvailable = max(0, paneHeight - headBlockHeight - steeringFooterHeight.actual
            - WorkflowCompactMetrics.regularRootPadding * 2 - WorkflowCompactMetrics.regularInner)
        let maximumInspector = max(0, steeringAvailable - 80)
        let inspectorReading = approvalDecisionMinimum > 0 ? CallerApprovalPinnedLayout.minimumCardViewport : 0
        let rootFeedMinimum = min(WorkflowSelectedPaneSizing.transcriptFloor,
                                  max(32, maximumInspector - columnChrome.actual - approvalDecisionMinimum - inspectorReading))
        let inspectorMinimum = hasSelectedInspector(state)
            ? columnChrome.actual + approvalDecisionMinimum + inspectorReading + rootFeedMinimum : 0
        let preferredBody = max(80, min(120, steeringAvailable - inspectorMinimum))
        let activityLimit = max(0, steeringAvailable - preferredBody)
        let rootActivityHeight = hasActivity ? min(activityLimit, max(steeringAvailable * 0.35, inspectorMinimum)) : 0
        Group {
            if viewModel.steeringOwnsComposer, !usesRetainedSteering(state) {
                // Measure the root's available bounds independently of its scrolling content.
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
                    .overlay(alignment: .top) {
                        selectedContent(state, fallback: fallback, suppressPlaceholder: suppressPlaceholder,
                                        allocation: (rootActivityHeight, rootFeedMinimum))
                            .frame(height: paneHeight, alignment: .top)
                    }
                    .clipped()
            } else {
                selectedContent(state, fallback: fallback, suppressPlaceholder: suppressPlaceholder,
                                allocation: (rootActivityHeight, rootFeedMinimum))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
            }
        }
        .environment(\.workflowInspectorApprovalController, selectedApprovalController)
        .environment(\.workflowInspectorRootApprovalController, selectedRootApprovalController)
        .environment(\.workflowInspectorCallScrollAcknowledged, acknowledgeCallScroll)
        .task(id: inlineApprovalTarget) { startInlineApprovals() }
        .task(id: rootApprovalTarget) { await startRootApprovals() }
        .onChange(of: rootApprovalScope) { _, scope in
            guard let scope, let controller = selectedRootApprovalController else { return }
            controller.updateRootScope(scope)
            controller.requestRefresh()
        }
        .onDisappear { inlineApprovalController?.stop(); rootApprovalController?.stop() }
        .onPreferenceChange(WorkflowSelectedColumnChromeKey.self) { columnChrome = $0 }
        // Inspector approval demand continues to size ordinary worker panes.
        .onPreferenceChange(CallerApprovalDemandKey.self) {
            approvalDemand = $0.reserved
            approvalDecisionMinimum = $0.decisionBarMinimum
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskScreenStyle.Colors.pageBackground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-selected-sidebar")
    }

    private func selectedContent(_ state: WorkflowRunSidebarPresentation, fallback: Bool,
                                 suppressPlaceholder: Bool, allocation: (height: CGFloat, feedMinimum: CGFloat)) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                WorkflowSelectedHead(viewModel: viewModel)
                if state.attempts.count > 1, !state.isOnDemand {
                    Picker("Attempt", selection: Binding(get: { state.activationID ?? "" }, set: { viewModel.selectActivation($0) })) {
                        ForEach(state.attempts) { attempt in Text(attempt.title).tag(attempt.id) }
                    }.padding(.horizontal, 12)
                }
                Divider()
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headBlockHeight = $0 }
            if !usesInlineDocument(state) { topRegion(state) }
            if usesRetainedSteering(state) {
                activityRegion(state, suppressPlaceholder: suppressPlaceholder)
                Divider()
                WorkflowSteeringFooter(viewModel: viewModel, retainedReply: !viewModel.steeringFailedQueue)
                    .padding(.horizontal, 12)
                    .padding(.top, viewModel.steeringFailedQueue ? 12 : 0)
                    .padding(.bottom, 12)
            } else if viewModel.steeringOwnsComposer {
                activityRegion(state, suppressPlaceholder: suppressPlaceholder)
                    .environment(\.rootApprovalFeedMinimum, allocation.feedMinimum)
                    .environment(\.compactRootApprovalCoexistence, false)
                    .frame(height: allocation.height)
                    .clipped()
                WorkflowSteeringPanel(viewModel: viewModel,
                                      ownsFallbackApproval: fallback, showsFallbackBubbles: !hasSelectedInspector(state),
                                      rootApprovalController: selectedRootApprovalController, ownsRootApprovalObservation: false,
                                      taskApprovalController: selectedApprovalController, ownsTaskApprovalObservation: false,
                                      onFooterHeight: { steeringFooterHeight = $0 })
            } else {
                activityRegion(state, suppressPlaceholder: suppressPlaceholder)
                if showsFallbackComposer(state) {
                    WorkflowActivityMessageComposer(viewModel: viewModel,
                                                    showsBubbles: !usesInlineDocument(state) && viewModel.nativeActivity == nil,
                                                    composerEdge: selectedFallbackComposerEdge,
                                                    selectedTaskInspector: usesInlineDocument(state) && viewModel.activityMessageTarget.taskID != nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func activityRegion(_ state: WorkflowRunSidebarPresentation, suppressPlaceholder: Bool) -> some View {
        if let native = viewModel.nativeActivity {
            WorkflowNativeActivityView(model: native, messages: viewModel.activityMessageBubbles,
                                       onCancel: viewModel.cancelActivityMessage, isCancelDisabled: viewModel.isBusy,
                                       leadingContent: inspectorDocument(state).rows, composerEdge: selectedFallbackComposerEdge,
                                       callReveal: inspectorDocument(state).callReveal,
                                       approvalContent: nativeApprovalContent,
                                       approvalReveal: selectedApprovalController?.reveal,
                                       onApprovalScrollAcknowledged: { id, token in
                                           selectedApprovalController?.acknowledgeScroll(requestID: id, token: token)
                                       }, onCallScrollAcknowledged: acknowledgeCallScroll)
                .id(native.executionID)
        } else if let child = state.childRunID {
            Button("Open workflow") { viewModel.openRun(child) }.padding(12)
            Spacer()
        } else if let activity = viewModel.selectedActivity {
            if suppressPlaceholder {
                if let details = unavailableDetails(state, activity) { WorkflowCallDetailsView(details: details) }
            } else {
                WorkflowSelectedActivityView(activity: activity, unavailableDetails: unavailableDetails(state, activity),
                                             showsTaskTitle: state.header.kind == .orchestrator,
                                             fallbackMessages: viewModel.activityMessageBubbles,
                                             onCancelFallbackMessage: viewModel.cancelActivityMessage,
                                             cancelDisabled: viewModel.isBusy)
                    .environment(\.workflowInspectorDocument, inspectorDocument(state))
                    .environment(\.rootApprovalCoexistence, viewModel.steeringOwnsComposer)
                    .id(ObjectIdentifier(activity))
                    .publishViewEvent(from: activity, to: viewEvent)
            }
        } else if usesInlineDocument(state) {
            WorkflowInspectorFiniteDocument(document: inspectorDocument(state),
                protectsTrailingContent: viewModel.activityMessageBubbles.contains(where: \.isPinned)) {
                if let details = state.callDetails { WorkflowCallDetailsView(details: details, naturalHeight: true) }
                Text(state.attempts.isEmpty ? "Not started" : "No task activity")
                    .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                if let controller = selectedApprovalController { WorkflowInspectorApprovalCards(controller: controller) }
                WorkMessageBubblesView(bubbles: viewModel.activityMessageBubbles, onCancel: viewModel.cancelActivityMessage,
                                       isCancelDisabled: viewModel.isBusy)
            }
        } else if WorkflowCallDetails.isShown(isOnDemand: state.isOnDemand, hasDetails: state.callDetails != nil,
                                              hasActivity: false, activityShowsConversation: false), let details = state.callDetails {
            WorkflowCallDetailsView(details: details)
        } else if !usesSteeringTranscript {
            ContentUnavailableView(state.attempts.isEmpty ? "Not started" : "No task activity", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Attributable root conversation replaces only the legacy empty activity drawing.
    private var usesSteeringTranscript: Bool {
        guard viewModel.steeringOwnsComposer else { return false }
        let steering = viewModel.steering
        return !steering.messages.isEmpty || steering.statusLine?.isEmpty == false
            || steering.note?.isEmpty == false || steering.opensNeedsYou
    }

    /// The retained column remains authoritative; fallback authority uses the existing guarded target.
    private var exactApprovalTaskID: String? {
        guard viewModel.runSidebar.approval.mounts else { return nil }
        if viewModel.steeringOwnsComposer {
            if viewModel.nativeActivity == nil, let activity = viewModel.selectedActivity,
               let column = activity.columns.first(where: { $0.id == activity.selectedConversationID }) {
                guard column.inspectorApproval != nil || viewModel.activityMessageTarget.taskID == column.task.taskID else { return nil }
                return column.task.taskID
            }
            // This is the same exact issued-task target and gate the fallback panel already admits.
            return viewModel.activityMessageTarget.taskID
        }
        guard usesInlineDocument(viewModel.runSidebar) else { return nil }
        if viewModel.nativeActivity == nil, let activity = viewModel.selectedActivity,
           let column = activity.columns.first(where: { $0.id == activity.selectedConversationID }) {
            return column.inspectorApproval == nil ? nil : column.task.taskID
        }
        return viewModel.activityMessageTarget.taskID
    }

    private var inlineApprovalTarget: String? {
        exactApprovalTaskID.map { $0 + (viewModel.runSidebar.approval.polls ? ":poll" : ":settled") }
    }

    private var selectedApprovalController: CallerApprovalController? {
        guard let taskID = exactApprovalTaskID, let controller = inlineApprovalController,
              inlineApprovalTaskID == taskID else { return nil }
        return controller
    }

    private func startInlineApprovals() {
        guard let taskID = exactApprovalTaskID else { inlineApprovalController?.stop(); inlineApprovalTaskID = nil; return }
        let controller: CallerApprovalController
        if let existing = inlineApprovalController { controller = existing } else {
            controller = CallerApprovalController(useCase: approvalUseCaseOverride?()
                ?? CallerApprovalRepository(environment: approvalEnvironment, owner: approvalResponseOwner),
                pendingDisclosures: true, retainsOutcomeFocus: true)
            inlineApprovalController = controller
        }
        controller.start(taskID: taskID, polls: viewModel.runSidebar.approval.polls)
        inlineApprovalTaskID = taskID
    }

    private var nativeApprovalContent: ActivityFeedSupplementaryRow? {
        guard !viewModel.steeringOwnsComposer, let controller = selectedApprovalController,
              let taskID = exactApprovalTaskID else { return nil }
        let status = ActivityFeedSupplementaryRow.ApprovalStatus(loading: controller.isLoading,
            submitting: controller.isSubmitting || controller.isResponseQueued, hasMore: controller.nextCursor != nil,
            limited: controller.acquisitionLimited, error: controller.error)
        let entries = controller.cards.map { ActivityFeedApprovalEntry(source: .task(taskID), card: $0) }
        return .init(scope: taskID, kind: .approvalStatus, input: .approvalCards(entries, status),
                     content: AnyView(WorkflowInspectorApprovalCards(controller: controller)))
    }

    private struct RootApprovalTarget: Equatable {
        let runID: String
        let polls: Bool
    }

    private var rootApprovalTarget: RootApprovalTarget? {
        guard viewModel.rootOwnsCallerApprovals, let run = viewModel.selectedRun else { return nil }
        return RootApprovalTarget(runID: run.id, polls: WorkflowRootApprovalScope.shouldPoll(run: run))
    }

    private var rootApprovalScope: WorkflowRootApprovalScope? {
        rootApprovalTarget.flatMap { _ in viewModel.selectedRun.map(WorkflowRootApprovalScope.init) }
    }

    private var selectedRootApprovalController: CallerApprovalController? {
        guard rootApprovalTarget?.runID == rootApprovalRunID, rootApprovalTarget != nil else { return nil }
        return rootApprovalController
    }

    private func startRootApprovals() async {
        guard let target = rootApprovalTarget, let scope = rootApprovalScope else {
            rootApprovalController?.stop(); rootApprovalRunID = nil
            return
        }
        let controller: CallerApprovalController
        if let existing = rootApprovalController { controller = existing } else {
            controller = CallerApprovalController(useCase: approvalUseCaseOverride?()
                ?? CallerApprovalRepository(environment: approvalEnvironment, owner: approvalResponseOwner),
                pendingDisclosures: true, retainsOutcomeFocus: true)
            rootApprovalController = controller
        }
        rootApprovalRunID = target.runID
        await controller.selectTarget(taskID: nil, workflowRunID: target.runID, rootScope: scope)
        while target.polls, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await controller.refresh()
        }
    }

    private func acknowledgeCallScroll(_ token: UUID) {
        guard let reveal = callReveal, reveal.token == token, !reveal.takesFocus else { return }
        callReveal = nil
    }

    private func usesRetainedSteering(_ state: WorkflowRunSidebarPresentation) -> Bool {
        viewModel.steeringOwnsComposer && hasSelectedInspector(state)
    }

    private func usesInlineDocument(_ state: WorkflowRunSidebarPresentation) -> Bool {
        usesRetainedSteering(state)
            || (state.header.kind != .orchestrator && !viewModel.steeringOwnsComposer && state.childRunID == nil)
    }

    private var selectedFallbackComposerEdge: Bool {
        let state = viewModel.runSidebar
        return usesInlineDocument(state) && showsFallbackComposer(state)
            && viewModel.activityMessageTarget.taskID != nil && viewModel.activityMessageReadError == nil
    }

    /// Explicit, complete version inputs keep hosted context measurement and updates coherent.
    private func inspectorDocument(_ state: WorkflowRunSidebarPresentation) -> WorkflowInspectorDocument {
        guard usesInlineDocument(state) else { return WorkflowInspectorDocument() }
        if usesRetainedSteering(state) {
            return WorkflowInspectorDocument(isEnabled: true, composerEdge: !viewModel.steeringFailedQueue,
                followingContent: WorkflowRetainedSteeringDocument.rows(viewModel: viewModel, controller: selectedRootApprovalController),
                retainedSteering: true, rootApprovalSource: viewModel.selectedRun.map { .workflowRun($0.id) })
        }
        let scope = state.node?["id"]?.stringValue ?? "selected"
        let activeReveal = callReveal?.activationID == state.activationID ? callReveal : nil
        var rows: [ActivityFeedSupplementaryRow] = []
        if state.showsGoal, let run = viewModel.selectedRun {
            let goalInput = ActivityFeedSupplementaryRow.GoalInput(presentation: viewModel.goalPresentation(for: run),
                revision: run.goalRevision, canRevise: run.canReviseGoal,
                sharedAnswering: run.sharedAnswering, draft: viewModel.goalDraft,
                error: viewModel.goalRevisionError, receipt: viewModel.goalAnsweredElsewhere(for: state.goal),
                savedDraft: viewModel.interactionSavedDraft, busy: viewModel.isBusy)
            rows.append(.init(scope: scope, kind: .goal, input: .goal(goalInput),
                              content: AnyView(WorkflowGoalView(viewModel: viewModel, run: run, naturalHeight: true))))
        }
        if state.isOnDemand {
            rows.append(.init(scope: scope, kind: .calls, input: .calls(isEmpty: state.callRows.isEmpty), content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Runs only when the orchestrator calls it, one call at a time.")
                        .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                    Text("CALLS").font(.hf(.caption, weight: .semibold)).foregroundStyle(Color.tertiaryText)
                    if state.callRows.isEmpty { captionText("Not called yet.") }
                })))
            for call in state.callRows {
                let rowID = "workflow-inspector-\(scope)-callSelector-\(call.id)"
                let reveal = activeReveal?.rowID == rowID ? activeReveal : nil
                let token = reveal?.takesFocus == true && reveal?.token != consumedCallFocus ? reveal?.token : nil
                rows.append(.init(scope: scope, kind: .callSelector,
                    input: .call(call, selected: state.activationID == call.id, focusToken: token), content: AnyView(
                    WorkflowInspectorCallSelector(row: call, selected: state.activationID == call.id, focusToken: token,
                        onSelect: {
                            let event = NSApp.currentEvent?.type
                            let keyboard = event == .keyDown || event == .keyUp
                            callReveal = .init(rowID: rowID, token: UUID(), takesFocus: keyboard, activationID: call.id)
                            consumedCallFocus = nil
                            viewModel.selectActivation(call.id)
                        }, onOpenTask: viewModel.openOwnerTask,
                        onFocusAcknowledged: { token in
                            consumedCallFocus = token
                            if callReveal?.token == token { callReveal = nil }
                        })), key: call.id))
            }
        }
        if let caption = state.caption, !state.isOnDemand || !state.callRows.isEmpty {
            rows.append(.init(scope: scope, kind: .caption, input: .caption(caption), content: AnyView(captionText(caption))))
        }
        if viewModel.nativeActivity != nil, let details = state.callDetails {
            rows.append(.init(scope: scope, kind: .callDetails, input: .details(details),
                              content: AnyView(WorkflowCallDetailsView(details: details, naturalHeight: true))))
        }
        return WorkflowInspectorDocument(rows: rows, activationID: state.activationID,
                                         selectedCallID: state.activationID, isEnabled: true, composerEdge: selectedFallbackComposerEdge,
                                         callReveal: activeReveal)
    }

    /// The region above the transcript: the goal and caption of a worker, or an on-demand node's intro and calls.
    @ViewBuilder
    private func topRegion(_ state: WorkflowRunSidebarPresentation) -> some View {
        let reserved = headBlockHeight + (showsFallbackComposer(state) ? composerHeight : 0) + columnChrome.actual + ParallelLayout.dividerWidth
        switch state.header.kind {
        case .worker:
            if state.showsGoal || state.caption != nil {
                WorkflowSelectedScrollRegion(paneHeight: paneHeight, reserved: reserved, approvalDemand: approvalDemand) {
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing16) {
                        if state.showsGoal, let run = viewModel.selectedRun { WorkflowGoalView(viewModel: viewModel, run: run) }
                        if let caption = state.caption { captionText(caption) }
                    }.padding(HfRadius.Metrics.spacing16)
                }
                Divider()
            }
        case .onDemand:
            WorkflowSelectedScrollRegion(paneHeight: paneHeight, reserved: reserved, approvalDemand: approvalDemand) {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing16) {
                    Text("Runs only when the orchestrator calls it, one call at a time.")
                        .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                        Text("CALLS").font(.hf(.caption, weight: .semibold)).foregroundStyle(Color.tertiaryText)
                        if state.callRows.isEmpty {
                            captionText("Not called yet.")
                        } else {
                            WorkflowOnDemandCallList(rows: state.callRows, selectedID: state.activationID,
                                                     onSelect: viewModel.selectActivation, onOpenTask: viewModel.openOwnerTask)
                        }
                    }
                    if let caption = state.caption, !state.callRows.isEmpty {
                        Divider()
                        captionText(caption)
                    }
                }.padding(HfRadius.Metrics.spacing16)
            }
            Divider()
        case .orchestrator:
            EmptyView()
        }
    }

    private func hasSelectedInspector(_ state: WorkflowRunSidebarPresentation) -> Bool {
        guard viewModel.nativeActivity == nil, state.childRunID == nil, let activity = viewModel.selectedActivity else { return false }
        return activity.columns.contains { $0.id == activity.selectedConversationID }
    }

    /// Only the selected column in the branch actually rendered by this sidebar can own the approval.
    private func inspectorOwnsApproval(_ state: WorkflowRunSidebarPresentation) -> Bool {
        guard viewModel.nativeActivity == nil, state.childRunID == nil, let activity = viewModel.selectedActivity,
              let column = activity.columns.first(where: { $0.id == activity.selectedConversationID }) else { return false }
        return column.inspectorApproval != nil
    }

    /// The pane's own composer: shown while no inspector column (with its own composer) is on screen.
    private func showsFallbackComposer(_ state: WorkflowRunSidebarPresentation) -> Bool {
        viewModel.nativeActivity != nil || state.childRunID != nil
            || viewModel.selectedActivity == nil || viewModel.selectedActivity?.columns.isEmpty == true
    }

    /// The call's details when its activity exists but cannot show the conversation, so they stay reachable.
    private func unavailableDetails(_ state: WorkflowRunSidebarPresentation, _ activity: ParallelVM) -> WorkflowCallDetails? {
        let shows = activity.columns.contains { $0.id == activity.selectedConversationID }
        return WorkflowCallDetails.isShown(isOnDemand: state.isOnDemand, hasDetails: state.callDetails != nil,
                                           hasActivity: true, activityShowsConversation: shows) ? state.callDetails : nil
    }

    private func captionText(_ value: String) -> some View {
        Text(value).font(.hf(.caption)).foregroundStyle(Color.tertiaryText).textSelection(.enabled)
    }
}

#if DEBUG
#Preview { WorkflowSelectedSidebar(viewModel: WorkflowPreview.make(run: true)) }

#Preview("Workflow selected sidebar - not started") {
    WorkflowSelectedSidebar(viewModel: WorkflowPreview.makeNotStartedNodeRun())
}
#endif
