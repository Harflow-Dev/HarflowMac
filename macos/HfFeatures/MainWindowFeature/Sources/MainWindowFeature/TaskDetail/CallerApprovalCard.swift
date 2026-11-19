import AppKit
import Foundation
import HfRepository
import HfUI
import MonitorCore
import SwiftEnvironment
import SwiftUI

// MARK: - CallerApprovalUseCase

@MainActor
protocol CallerApprovalUseCase {
    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage
    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest
    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest
    func canReviewAgain(_ request: CallerApprovalRequest, context: ApprovalResponseContext) async -> Bool
    func responseContext() throws -> ApprovalResponseContext?
    func isResponseContextCurrent(_ context: ApprovalResponseContext) -> Bool
    func retainedResponse(_ request: CallerApprovalRequest, context: ApprovalResponseContext) -> ApprovalResponseOutcome?
    func respond(_ request: CallerApprovalRequest, decision: String, context: ApprovalResponseContext?) async throws -> CallerApprovalRequest
    func supportsMonitorResponseForCallerApprovals() async throws -> Bool
}

extension CallerApprovalUseCase {
    func canReviewAgain(_: CallerApprovalRequest, context _: ApprovalResponseContext) async -> Bool { false }
    func responseContext() throws -> ApprovalResponseContext? { nil }
    func isResponseContextCurrent(_: ApprovalResponseContext) -> Bool { false }
    func retainedResponse(_: CallerApprovalRequest, context _: ApprovalResponseContext) -> ApprovalResponseOutcome? { nil }
    func respond(_ request: CallerApprovalRequest, decision: String, context _: ApprovalResponseContext?) async throws -> CallerApprovalRequest {
        try await respond(request, decision: decision)
    }

    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { false }
}

extension CallerApprovalRepository: CallerApprovalUseCase {
    func responseContext() throws -> ApprovalResponseContext? { try responseContextValue() }
    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        throw ToolError.unknownOutcome(message: "Refresh to review the current action.")
    }

    func respond(_ request: CallerApprovalRequest, decision: String, context: ApprovalResponseContext?) async throws -> CallerApprovalRequest {
        guard let context else { throw ToolError.unknownOutcome(message: "Refresh to review the current action.") }
        return try await respond(request, decision: decision, context: context)
    }
}

// MARK: - CallerApprovalUseCaseOverride

extension EnvironmentValues {
    /// Test-only seam: when set, `CallerApprovalPanel` builds its controller from this use case instead of a
    /// `CallerApprovalRepository` over the global environment. Production never sets it. It is read once inside the
    /// panel's `.task` and is not part of the task identity.
    @Entry var callerApprovalUseCaseOverride: (@MainActor @Sendable () -> any CallerApprovalUseCase)?
}

// MARK: - CallerApprovalPanel

/// Workflows retain the run-sidebar location. Task detail owns its controller in the VM instead.
///
/// With `pinsDecisionControls` (the workflow inspector column) the decision controls of every request awaiting a decision
/// leave the card and sit in bars under the scrolling cards, and the panel reports its layout demand through
/// `CallerApprovalDemandKey` so the pane can give the card its natural height first. The default keeps task detail and
/// the run sidebar unchanged.
struct CallerApprovalPanel: View {
    var taskID: String?
    var workflowRunID: String?
    var polls = true
    var pinsDecisionControls = false
    @State private var controller: CallerApprovalController?
    @GlobalEnvironment(\.toolEnvironmentRepository) private var environment
    @GlobalEnvironment(\.approvalResponseOwner) private var approvalResponseOwner
    @Environment(\.callerApprovalUseCaseOverride) private var useCaseOverride

    nonisolated static func containsOptIn(_ value: JSONValue) -> Bool {
        if let object = value.objectValue {
            return object["caller_approvals"]?.boolValue == true || object.values.contains(where: containsOptIn)
        }
        return value.arrayValue?.contains(where: containsOptIn) ?? false
    }

    var body: some View {
        Group {
            if pinsDecisionControls {
                // The zero-size leaf keeps the pinned panel a real view while it shows nothing, so its polling task starts
                // and the pane can learn its demand. The default panel keeps its original start condition.
                ZStack(alignment: .top) {
                    Color.clear.frame(width: HfRadius.Metrics.zero, height: HfRadius.Metrics.zero)
                    if let controller, !controller.cards.isEmpty || controller.error != nil {
                        CallerApprovalPinnedLayout(controller: controller)
                    }
                }
            } else if let controller, !controller.cards.isEmpty || controller.error != nil {
                CallerApprovalCard(controller: controller).padding(HfRadius.Metrics.spacing12)
            }
        }
        .task(id: "\(taskID ?? ""):\(workflowRunID ?? ""):\(polls)") {
            let useCase: any CallerApprovalUseCase = useCaseOverride?()
                ?? CallerApprovalRepository(environment: environment, owner: approvalResponseOwner)
            let value = CallerApprovalController(useCase: useCase)
            controller = value
            await value.selectTarget(taskID: taskID, workflowRunID: workflowRunID)
            while polls, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await value.refresh()
            }
        }
        .onDisappear { controller?.stop() }
    }
}

// MARK: - CallerApprovalDemand

/// What the pinned panel needs from the space around it, measured from its content and never from its own allocation.
struct CallerApprovalDemand: Equatable {
    /// The panel's natural height. While a request is visually pending it is the height of the cards awaiting a decision
    /// (they sort first) with their padding, plus every decision bar; settled, expired and unknown-delivery rows and "Load
    /// more" scroll below inside the region and never count. With none awaiting it is the whole content.
    var natural: CGFloat = 0
    /// True while any request is visually pending (`isVisuallyPending`: includes reserved, sending and unknown-disposition
    /// requests), including one whose controls are withheld (refused, busy, not current).
    var awaitingDecision = false

    /// The height the pane must leave the region: the natural height while a request awaits a decision, else nothing.
    var reserved: CGFloat { awaitingDecision ? natural : 0 }
}

/// Reports the pinned panel's `CallerApprovalDemand` to the inspector column and the pane. Only one column is mounted in
/// the selected pane, so the largest value wins.
struct CallerApprovalDemandKey: PreferenceKey {
    static let defaultValue = CallerApprovalDemand()
    static func reduce(value: inout CallerApprovalDemand, nextValue: () -> CallerApprovalDemand) {
        let next = nextValue()
        if next.natural > value.natural || (next.natural == value.natural && next.awaitingDecision) { value = next }
    }
}

// MARK: - CallerApprovalRegionFrameProbe

/// An invisible AppKit view behind the pinned panel with the panel's exact frame, so hosted tests read the region's own
/// bounds (its accessibility group stops at the last child). It takes no events and is not an accessibility element.
private struct CallerApprovalRegionFrameProbe: NSViewRepresentable {
    static let identifier = "workflow-selected-approval-frame"

    /// Never the hit-test target, so it cannot take a click from anything it sits behind.
    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(Self.identifier)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - CallerApprovalPinnedLayout

/// The panel's pinned layout: the cards scroll; the decision controls of each request awaiting a decision sit in a bar
/// under them. One bar is never inside a scroll view. With several bars each names its request, and when the stacked bars
/// exceed the room the bar stack itself scrolls, so every action stays reachable; it never takes the card viewport below
/// `minimumCardViewport` (or the awaiting cards' own height when that is smaller) and never below the tallest single bar.
/// The caller frames this view at the region height; the layout fills exactly that height and clips.
struct CallerApprovalPinnedLayout: View {
    @Bindable var controller: CallerApprovalController
    @State private var contentHeight: CGFloat = 0
    @State private var cardHeights: [String: CGFloat] = [:]
    @State private var measuredBarsHeight: CGFloat = 0
    @State private var barHeights: [String: CGFloat] = [:]

    /// The card viewport kept while several bars scroll.
    static let minimumCardViewport: CGFloat = 80

    /// The height of the bar stack's viewport. A single bar is never scrolled, so it keeps its natural height. Several bars
    /// take their natural height when it fits; otherwise they are capped so the card viewport keeps `minCardViewport`, but
    /// never below the tallest single bar (with its bottom padding) and never above the region.
    static func barViewportHeight(barCount: Int, barsHeight: CGFloat, tallestBar: CGFloat, region: CGFloat,
                                  minCardViewport: CGFloat) -> CGFloat {
        guard barCount > 1 else { return barsHeight }
        return max(0, min(barsHeight, max(tallestBar, region - minCardViewport), region))
    }

    var body: some View {
        let bars = CallerApprovalPresentation.pinnedBars(controller.cards)
        let awaiting = controller.cards.filter(\.awaitingDecision)
        // With no bar the measured value is stale (an empty stack reports nothing), so it counts as zero.
        let barsHeight = bars.isEmpty ? HfRadius.Metrics.zero : measuredBarsHeight
        let spacing = HfRadius.Metrics.spacing8
        let padding = HfRadius.Metrics.spacing12
        // The cards awaiting a decision come first; only they (and the bars) are demanded.
        let awaitingContent: CGFloat? = awaiting.isEmpty ? nil
            : awaiting.reduce(2 * padding) { $0 + (cardHeights[$1.id] ?? 0) } + spacing * CGFloat(awaiting.count - 1)
        let tallestBar = (bars.compactMap { barHeights[$0.id] }.max() ?? 0) + padding
        GeometryReader { proxy in
            let region = proxy.size.height
            let barsShown = Self.barViewportHeight(barCount: bars.count, barsHeight: barsHeight, tallestBar: tallestBar, region: region,
                                                   minCardViewport: min(awaitingContent ?? contentHeight, Self.minimumCardViewport))
            VStack(spacing: HfRadius.Metrics.zero) {
                ScrollView {
                    CallerApprovalCard(controller: controller, pinnedBarIDs: Set(bars.map(\.id)), awaitingFirst: true,
                                       onCardHeight: { id, height in
                                           if cardHeights[id] != height { cardHeights[id] = height }
                                       })
                        .padding(padding)
                        .frame(maxWidth: .infinity)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                        .background(ScrollChrome())
                }
                .frame(height: max(0, region - barsShown))
                barStack(bars, viewport: barsShown)
            }
            .frame(height: region, alignment: .top)
            .clipped()
        }
        .background(CallerApprovalRegionFrameProbe())
        .onChange(of: controller.cards.map(\.id)) { _, ids in
            let live = Set(ids)
            if !cardHeights.keys.allSatisfy(live.contains) { cardHeights = cardHeights.filter { live.contains($0.key) } }
        }
        .preference(key: CallerApprovalDemandKey.self, value: CallerApprovalDemand(
            natural: (awaitingContent ?? contentHeight) + barsHeight, awaitingDecision: !awaiting.isEmpty))
    }

    @ViewBuilder
    private func barStack(_ bars: [CallerApprovalCardModel], viewport: CGFloat) -> some View {
        if bars.count > 1 {
            ScrollView { barContent(bars) }
                .background(ScrollChrome())
                .frame(height: viewport)
                .accessibilityIdentifier("approval-decision-bars")
        } else if bars.count == 1 {
            barContent(bars)
        } else {
            barContent([])
        }
    }

    private func barContent(_ bars: [CallerApprovalCardModel]) -> some View {
        VStack(spacing: HfRadius.Metrics.spacing8) {
            ForEach(bars) { bar in
                CallerApprovalDecisionBar(model: bar, showsLabel: bars.count > 1,
                                          respond: { controller.submit($0, requestID: bar.id) })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if barHeights[bar.id] != height { barHeights[bar.id] = height }
                    }
            }
        }
        .padding(.horizontal, HfRadius.Metrics.spacing12)
        .padding(.bottom, bars.isEmpty ? HfRadius.Metrics.zero : HfRadius.Metrics.spacing12)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredBarsHeight = $0 }
    }
}

// MARK: - CallerApprovalDecisionBar

/// One request's pinned decision controls, styled like the pending card they belong to. With several bars it opens with a
/// one-line label naming its request (tool and command, truncated in the middle so requests that differ only at the end stay
/// distinguishable), with the full text as its help and accessibility label.
struct CallerApprovalDecisionBar: View {
    let model: CallerApprovalCardModel
    var showsLabel = false
    let respond: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
            if showsLabel {
                Text(model.barLabel)
.font(.hf(.caption, weight: .semibold))
.foregroundStyle(Color.warningFG)
                    .lineLimit(1)
.truncationMode(.middle)
                    .help(model.barLabel)
                    .accessibilityLabel(model.barLabel)
                    .accessibilityIdentifier("approval-bar-label-\(model.id)")
            }
            CallerApprovalDecisionControls(model: model, respond: respond)
        }
        .padding(.horizontal, HfRadius.Metrics.spacing12)
        .padding(.vertical, HfRadius.Metrics.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warningBG, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.warningFG))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-bar-\(model.id)")
    }
}

// MARK: - CallerApprovalDecisionControls

/// "Approve once" and "Reject" for one pending request, inline in its card or in a pinned bar.
struct CallerApprovalDecisionControls: View {
    let model: CallerApprovalCardModel
    let respond: (String) -> Void
    var onFocusAcknowledged: ((UUID) -> Void)?
    var isFocusReady: () -> Bool = { true }

    var body: some View {
        HStack {
            ApprovalDecisionButton(title: model.submitting ? "Submitting…" : "Approve once",
                                   enabled: model.canRespond, identifier: "approval-approve-\(model.id)",
                                   token: onFocusAcknowledged == nil ? nil : model.focusToken, isFocusReady: isFocusReady,
                                   action: { respond("approve") }, acknowledge: { onFocusAcknowledged?($0) })
                .fixedSize()
            Button("Reject", role: .destructive) { respond("reject") }
                .accessibilityIdentifier("approval-reject-\(model.id)")
        }.disabled(!model.canRespond)
    }
}

// MARK: - CallerApprovalCard

struct CallerApprovalCard: View {
    @Bindable var controller: CallerApprovalController
    /// Requests whose decision controls sit in a pinned bar outside this view, so their cards draw none.
    var pinnedBarIDs: Set<String> = []
    /// Renders the cards awaiting a decision first, each group in its own order. The pinned panel sets it: a request the app's own
    /// ordering (`CallerApprovalPresentation.orderedBefore`) sorts among settled history (an unknown disposition that is still pending) must not sit under expanded history.
    var awaitingFirst = false
    /// Reports the laid-out height of every card, so the pinned panel can total those awaiting a decision.
    var onCardHeight: ((String, CGFloat) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            ForEach(awaitingFirst ? controller.cards.filter(\.awaitingDecision) + controller.cards.filter { !$0.awaitingDecision }
                        : controller.cards) { card in
                CallerApprovalRequestCard(model: card, respond: { decision in
                    controller.submit(decision, requestID: card.id)
                }, toggle: { controller.toggle(card.id) }, refresh: { controller.requestRefresh() },
                showsInlineDecisionControls: !pinnedBarIDs.contains(card.id))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    onCardHeight?(card.id, height)
                }
            }
            if controller.nextCursor != nil {
                Button("More requests available · Load more") { controller.requestRefresh(loadMore: true) }
                    .disabled(controller.isLoading || controller.isSubmitting)
            }
            if let error = controller.error { Text(error).font(.hf(.caption)).foregroundStyle(Color.failedRed).textSelection(.enabled) }
        }
    }
}

// MARK: - CallerApprovalRequestCard

struct CallerApprovalRequestCard: View {
    let model: CallerApprovalCardModel
    let respond: (String) -> Void
    let toggle: () -> Void
    var refresh: (() -> Void)?
    var onFocusAcknowledged: ((UUID) -> Void)?
    var isFocusReady: () -> Bool = { true }
    /// False when the decision controls are drawn elsewhere (a pinned bar); the card then omits them.
    var showsInlineDecisionControls = true

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            if model.pending {
                Text(model.source).font(.hf(.secondary, weight: .semibold)).foregroundStyle(Color.warningFG)
            } else {
                Button(action: toggle) {
                    HStack(alignment: .top) {
                        Image(systemName: model.expanded ? "chevron.down" : "chevron.right")
                        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                            Text(model.action.title)
                            Text(settledStatus).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.plain)
            }
            if model.expanded || model.pending { detail }
        }
        .padding(HfRadius.Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.pending ? Color.warningBG : Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(model.pending ? Color.warningFG : Color.hairline))
    }

    private var focusToken: UUID? { onFocusAcknowledged == nil ? nil : model.focusToken }

    private func acknowledgeFocus(_ token: UUID) { onFocusAcknowledged?(token) }

    private var settledStatus: String {
        var values = [model.request.text("disposition")]
        values += CallerApprovalPresentation.decisionSummary(model.request)
        if model.request.text("responder") == "monitor" { values.append("Answered from Harflow") }
        if model.request.text("responder") == "caller" { values.append("Answered by the owning caller") }
        if model.request.text("decided_by") == "harflow" { values.append("Rejected by Harflow") }
        values.append("Delivery: " + model.request.text("delivery"))
        return values.joined(separator: " · ")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            Text(model.action.title).font(.hf(.secondary, weight: .semibold))
            context
            ApprovalDetailsScroll(identifier: "approval-details-\(model.id)",
                                  label: "Requested action details for \(model.action.title)",
                                  token: model.canRespond ? nil : focusToken,
                                  isFocusReady: isFocusReady, acknowledge: acknowledgeFocus) {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                    ForEach(model.action.fields) { field in
                        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                            Text("\(field.label) · \(field.type)").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                            Text(verbatim: field.value)
.font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(Color.composerFill, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
.frame(maxWidth: .infinity, alignment: .leading)
            }
.frame(maxHeight: 220)
.fixedSize(horizontal: false, vertical: true)
            if let reason = model.request.raw["decision_reason"]?.stringValue, !reason.isEmpty {
                Text("Agent's stated reason").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                ScrollView { Text(verbatim: reason).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 96)
.font(.hf(.caption))
.fixedSize(horizontal: false, vertical: true)
            }
            if !model.pending {
                ForEach(CallerApprovalPresentation.resultLines(model.request), id: \.self) { Text($0).font(.hf(.caption)) }
            }
            if let notice = model.notice {
                Text(notice).font(.hf(.caption)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            }
            if model.showsRefresh || model.notice == CallerApprovalPresentation.refusalMessage(.notCurrent) {
                Button("Refresh") { refresh?() }.disabled(refresh == nil || model.submitting)
            }
            if model.pending, model.showsDecisionControls, showsInlineDecisionControls {
                CallerApprovalDecisionControls(model: model, respond: respond, onFocusAcknowledged: onFocusAcknowledged,
                                               isFocusReady: isFocusReady)
            }
        }
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
            if !model.request.text("task_title").isEmpty { Text("Agent task: \(model.request.text("task_title"))") }
            if !model.request.text("workflow_node_name").isEmpty { Text("Workflow node: \(model.request.text("workflow_node_name"))") }
            Text("Working directory: \(model.request.text("cwd"))")
            Text("Access level: \(model.request.text("freedom")) · Scope: \(model.request.text("scope"))")
            if let deadline = model.request.deadline { Text("Deadline: \(deadline.formatted())") }
        }
.font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
.textSelection(.enabled)
    }
}

#if DEBUG
@MainActor
private func approvalPreview(pending: Bool = true) -> some View {
    let request = CallerApprovalRequest(raw: [
        "request_id": .string("preview-request"), "task_id": .string("preview-task"),
        "tool_name": .string("Bash"), "cwd": .string("/workspace/repo"),
        "freedom": .string("write_in_repo"), "scope": .string("exact_action_once"),
        "disposition": .string(pending ? "pending" : "decided"),
        "delivery": .string(pending ? "pending" : "sent"), "execution_outcome": .string("unknown"),
        "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("swift test --filter PersistenceTests")])])
    ])
    let model = CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request),
                                        pending: pending, expanded: pending, canRespond: pending,
                                        notice: nil, submitting: false)
    return CallerApprovalRequestCard(model: model, respond: { _ in }, toggle: {})
        .padding()
.frame(width: 288)
}

#Preview("Pending approval · Light") { approvalPreview().preferredColorScheme(.light) }
#Preview("Pending approval · Dark") { approvalPreview().preferredColorScheme(.dark) }
#Preview("Settled approval") { approvalPreview(pending: false) }
#endif
