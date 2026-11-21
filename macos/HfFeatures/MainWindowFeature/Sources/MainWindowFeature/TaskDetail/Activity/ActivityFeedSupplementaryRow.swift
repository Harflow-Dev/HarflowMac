import HfUI
import MonitorCore
import SwiftUI

// MARK: - ActivityFeedSupplementaryRow

/// Versioned native document content. The explicit input participates in entry equality and
/// measurement caching; the hosted rendering is never an unversioned builder closure.
struct ActivityFeedSupplementaryRow: Equatable, Identifiable {
    enum Kind: String {
        case goal, caption, calls, callSelector, callDetails, taskContext, approvalStatus
        case steeringHistory, steeringMessage, steeringControls, taskActivityTail
    }

    enum Input: Equatable {
        case goal(GoalInput)
        case caption(String)
        case calls(isEmpty: Bool)
        case call(WorkflowOnDemandCallRow, selected: Bool, focusToken: UUID?)
        case details(WorkflowCallDetails)
        case taskContext(TaskContextInput)
        case steering(WorkflowSteeringDocumentInput)
        case steeringMessage(WorkflowSteeringPresentation.Message)
        case activityTail(ActivityFeedTailPresentation)
        case approval(ApprovalStatus)
        case approvalCards([ActivityFeedApprovalEntry], ApprovalStatus)
    }

    struct GoalInput: Equatable {
        var presentation: WorkflowGoalPresentation?
        var revision: Int
        var canRevise: Bool
        var sharedAnswering: Bool
        var draft: WorkflowGoalDraft?
        var error: String?
        var receipt: WorkflowInteractionReceipt?
        var savedDraft: String?
        var busy: Bool
    }

    struct TaskContextInput: Equatable {
        var showsTitle: Bool
        var title: String
        var subtitle: String
        var backend: String
        var status: String?
        var startedAt: Date?
        var duration: Double?
        var exitCode: Int?
        var takenOver: Bool
        var busy: Bool
        var allowsTerminal: Bool
        var hasSession: Bool
        var hasTakeover: Bool
        var hasAdopt: Bool
        var notice: String?
        var outcome: String?
        var summary: String?
        var count: String?
        var noCalls: String?
        var historyFocus: UUID?
    }

    struct ApprovalStatus: Equatable {
        var loading: Bool
        var submitting: Bool
        var hasMore: Bool
        var limited: Bool
        var error: String?
    }

    let scope: String
    let kind: Kind
    let input: Input
    let content: AnyView
    var key: String?
    var protectsActions: Bool {
        switch kind {
        case .goal, .callSelector, .taskContext, .approvalStatus, .steeringControls: true
        default: false
        }
    }

    var id: String { "workflow-inspector-\(scope)-\(kind.rawValue)" + (key.map { "-" + $0 } ?? "") }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.kind == rhs.kind && lhs.key == rhs.key && lhs.input == rhs.input
    }
}

// MARK: - WorkflowInspectorDocument

struct WorkflowInspectorDocument: Equatable {
    var rows: [ActivityFeedSupplementaryRow] = []
    var activationID: String?
    var selectedCallID: String?
    var isEnabled = false
    var composerEdge = false
    var callReveal: WorkflowInspectorCallReveal?
    var followingContent: [ActivityFeedDocumentEntry] = []
    var retainedSteering = false
    var rootApprovalSource: ActivityFeedApprovalEntry.Source?
}

extension EnvironmentValues {
    @Entry var workflowInspectorDocument = WorkflowInspectorDocument()
    @Entry var workflowInspectorFocusReady: () -> Bool = { false }
    @Entry var workflowInspectorCallScrollAcknowledged: (UUID) -> Void = { _ in }
    @Entry var workflowInspectorApprovalController: CallerApprovalController?
    @Entry var workflowInspectorRootApprovalController: CallerApprovalController?
    @Entry var workflowInspectorApprovalFocusReady: () -> Bool = { true }
    @Entry var workflowInspectorApprovalFrame: (String, CGRect) -> Void = { _, _ in }
}

// MARK: - ActivityFeedApprovalEntry

/// Presentation identity includes authority; raw request identifiers are not globally unique.
struct ActivityFeedApprovalEntry: Equatable {
    enum Source: Equatable { case task(String), workflowRun(String) }
    let source: Source
    var card: CallerApprovalCardModel
    var issuer: String?
    var pendingDisclosures = true

    var id: String {
        let scope = switch source {
        case .task(let id): "task-\(id)"
        case .workflowRun(let id): "run-\(id)"
        }
        return "activity-scoped-approval-\(scope)-\(card.id)"
    }
}

// MARK: - WorkflowInspectorCallReveal

struct WorkflowInspectorCallReveal: Equatable {
    let rowID: String
    let token: UUID
    let takesFocus: Bool
    var activationID: String?
}

// MARK: - WorkflowInspectorCallSelector

struct WorkflowInspectorCallSelector: View {
    let row: WorkflowOnDemandCallRow
    let selected: Bool
    let focusToken: UUID?
    let onSelect: () -> Void
    let onOpenTask: (String) -> Void
    let onFocusAcknowledged: (UUID) -> Void
    @Environment(\.workflowInspectorFocusReady) private var focusReady

    var body: some View {
        HStack(spacing: 8) {
            let status = StatusBadge.presentation(for: row.indicatorStatus)
            StatusIndicatorView(status.indicator, tint: status.tint.foreground)
            if row.isRunning, row.startedAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in selector(row.summary(now: timeline.date)) }
            } else { selector(row.summary(now: .now)) }
            if let taskID = row.taskID {
                Button("Open task") { onOpenTask(taskID) }.buttonStyle(QuietButtonStyle()).font(.hf(.caption))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: WorkflowSelectedPaneSizing.callRowHeight)
        .background(selected ? TaskScreenStyle.Colors.surfaceActive.color : Color.clear,
                    in: RoundedRectangle(cornerRadius: HfRadius.row))
    }

    private func selector(_ title: String) -> some View {
        ApprovalDecisionButton(title: title, enabled: true, identifier: "workflow-call-selector-" + row.id,
            token: focusToken, isFocusReady: focusReady, action: onSelect,
            acknowledge: onFocusAcknowledged, usesInlineStyle: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - WorkflowInspectorApprovalCards

/// Finite and native selected documents share the pane's exact task session.
struct WorkflowInspectorApprovalCards: View {
    @Bindable var controller: CallerApprovalController
    @Environment(\.workflowInspectorApprovalFocusReady) private var focusReady
    @Environment(\.workflowInspectorApprovalFrame) private var reportFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(controller.cards) { original in
                let card = admitted(original)
                CallerApprovalRequestCard(model: card,
                    respond: { controller.submit($0, requestID: card.id) }, toggle: { controller.toggle(card.id) },
                    refresh: { controller.requestRefresh() },
                    onFocusAcknowledged: { controller.acknowledgeFocus(requestID: card.id, token: $0) },
                    isFocusReady: focusReady, pendingDisclosures: true, nativeInlineDisclosure: true)
                    .id("workflow-finite-approval-" + card.id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workflow-activity-document")) } action: {
                        reportFrame(card.id, $0)
                    }
            }
            WorkflowInspectorApprovalStatus(controller: controller)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workflow-activity-document")) } action: {
                    reportFrame("workflow-approval-status", $0)
                }
        }.accessibilityIdentifier("workflow-selected-approval")
    }

    private func admitted(_ original: CallerApprovalCardModel) -> CallerApprovalCardModel {
        var card = original
        card.canRespond = card.canRespond && !controller.isLoading && !controller.isSubmitting && !controller.isResponseQueued
        return card
    }
}

// MARK: - WorkflowInspectorApprovalStatus

struct WorkflowInspectorApprovalStatus: View {
    var controller: CallerApprovalController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.isLoading { LoadingLabel("Loading approval requests…") }
            if controller.nextCursor != nil {
                Button("More requests available · Load more") { controller.requestRefresh(loadMore: true) }
                    .disabled(controller.isLoading || controller.isSubmitting)
            }
            if controller.acquisitionLimited {
                Text("The request read reached its limit. Refresh to review the current requests.")
                    .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
            }
            if let error = controller.error { Text(error).font(.hf(.caption)).foregroundStyle(Color.failedRed).textSelection(.enabled) }
            if !controller.cards.isEmpty || controller.error != nil || controller.acquisitionLimited {
                Button("Refresh") { controller.requestRefresh() }.disabled(controller.isLoading || controller.isSubmitting)
            }
        }.accessibilityIdentifier("workflow-selected-approval-status")
    }
}

// MARK: - WorkflowInspectorFiniteDocument

/// A finite selected pane retains one outer scroll and the same exact navigation targets.
struct WorkflowInspectorFiniteDocument<Content: View>: View {
    let document: WorkflowInspectorDocument
    var protectsTrailingContent = false
    @ViewBuilder let content: () -> Content
    @Environment(\.workflowInspectorCallScrollAcknowledged) private var acknowledgeCall
    @Environment(\.workflowInspectorApprovalController) private var controller
    @State private var edgeState = WorkflowInspectorFiniteEdgeState()

    private var protectsTrailingActions: Bool {
        protectsTrailingContent || controller.map {
            !$0.cards.isEmpty || $0.error != nil || $0.nextCursor != nil || $0.acquisitionLimited
        } == true
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(document.rows) { row in
                        row.content
.id(row.id)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workflow-activity-document")) } action: {
                                if row.protectsActions { edgeState.reportFrame(id: row.id, frame: $0) }
                            }
                    }
                    content()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workflow-activity-document")) } action: {
                            if protectsTrailingActions { edgeState.reportFrame(id: "finite-content", frame: $0) }
                        }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: "workflow-activity-document")
                .background(WorkflowInspectorFiniteEdgeProbe(state: edgeState, enabled: document.composerEdge,
                    protectedIDs: Set(document.rows.filter(\.protectsActions).map(\.id)
                        + (protectsTrailingActions ? ["finite-content"] : []))))
            }
            .environment(\.workflowInspectorFocusReady, { true })
            .environment(\.workflowInspectorApprovalFocusReady, { controller?.reveal == nil })
            .onChange(of: document.callReveal, initial: true) { _, reveal in
                guard let reveal else { return }
                proxy.scrollTo(reveal.rowID, anchor: .top)
                Task { @MainActor in
                    await Task.yield()
                    acknowledgeCall(reveal.token)
                }
            }
            .onChange(of: controller?.reveal, initial: true) { _, reveal in
                guard let reveal else { return }
                proxy.scrollTo("workflow-finite-approval-" + reveal.requestID, anchor: .top)
                Task { @MainActor in
                    await Task.yield()
                    controller?.acknowledgeScroll(requestID: reveal.requestID, token: reveal.token)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WorkflowInspectorHistoryBoundary

struct WorkflowInspectorHistoryBoundary: View {
    let text: String
    let focusToken: UUID?
    let onAdopt: (() -> Void)?
    let acknowledge: (UUID) -> Void
    @Environment(\.workflowInspectorFocusReady) private var focusReady

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ApprovalFocusLabel(text: text, identifier: "workflow-history-boundary", token: focusToken,
                               isReady: focusReady, acknowledge: acknowledge)
            if let onAdopt {
                Button("Load current activity", action: onAdopt)
                    .accessibilityIdentifier("workflow-load-current-activity")
            }
        }
    }
}

// MARK: - Ordered native companion content

/// Ordered supplementary content preserves independent approval sources in one native document.
enum ActivityFeedDocumentEntry: Equatable {
    case supplementary(ActivityFeedSupplementaryRow)
    case approval(ActivityFeedApprovalEntry)

    var nativeEntry: ActivityFeedNativeEntry {
        switch self {
        case .supplementary(let row): .supplementary(row)
        case .approval(let entry): .scopedApproval(entry, topSpacing: 12)
        }
    }
}

/// Reveal admission and acknowledgement carry the same authority as their native row.
struct ActivityFeedApprovalReveal: Equatable {
    let source: ActivityFeedApprovalEntry.Source
    let requestID: String
    let token: UUID

    init(source: ActivityFeedApprovalEntry.Source, reveal: CallerApprovalReveal) {
        self.source = source
        self.requestID = reveal.requestID
        self.token = reveal.token
    }
}
