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
    var suspended = false
    var pendingDisclosures = false
    var rootScope: WorkflowRootApprovalScope?
    /// A pane-owned session renders here without transferring discovery or teardown ownership.
    var suppliedController: CallerApprovalController?
    var ownsObservation = true
    @State private var controller: CallerApprovalController?
    @GlobalEnvironment(\.toolEnvironmentRepository) private var environment
    @GlobalEnvironment(\.approvalResponseOwner) private var approvalResponseOwner
    @Environment(\.callerApprovalUseCaseOverride) private var useCaseOverride

    private struct ObservationKey: Equatable {
        let taskID: String?
        let workflowRunID: String?
        let polls: Bool
        let suspended: Bool
        let rootID: String?
    }

    nonisolated static func containsOptIn(_ value: JSONValue) -> Bool {
        if let object = value.objectValue {
            return object["caller_approvals"]?.boolValue == true || object.values.contains(where: containsOptIn)
        }
        return value.arrayValue?.contains(where: containsOptIn) ?? false
    }

    var body: some View {
        let displayController = ownsObservation ? controller : suppliedController
        Group {
            if pendingDisclosures {
                ZStack(alignment: .top) {
                    Color.clear.frame(width: HfRadius.Metrics.zero, height: HfRadius.Metrics.zero)
                    if let controller = displayController { CallerApprovalRootCards(controller: controller, scope: rootScope) }
                }
            } else if pinsDecisionControls {
                // The zero-size leaf keeps the pinned panel a real view while it shows nothing, so its polling task starts
                // and the pane can learn its demand. The default panel keeps its original start condition.
                ZStack(alignment: .top) {
                    Color.clear.frame(width: HfRadius.Metrics.zero, height: HfRadius.Metrics.zero)
                    if let controller = displayController, !controller.cards.isEmpty || controller.error != nil {
                        CallerApprovalPinnedLayout(controller: controller)
                    }
                }
            } else if let controller = displayController, !controller.cards.isEmpty || controller.error != nil {
                CallerApprovalCard(controller: controller).padding(HfRadius.Metrics.spacing12)
            }
        }
        .task(id: ObservationKey(taskID: taskID, workflowRunID: workflowRunID, polls: polls,
                                  suspended: suspended, rootID: rootScope?.rootID)) {
            guard ownsObservation else { return }
            guard !suspended else { controller?.stop(); return }
            let value: CallerApprovalController
            if let controller {
                value = controller
            } else {
                let useCase: any CallerApprovalUseCase = useCaseOverride?()
                    ?? CallerApprovalRepository(environment: environment, owner: approvalResponseOwner)
                value = CallerApprovalController(useCase: useCase, pendingDisclosures: pendingDisclosures)
                controller = value
            }
            await value.selectTarget(taskID: taskID, workflowRunID: workflowRunID, rootScope: rootScope)
            while polls, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await value.refresh()
            }
        }
        .onChange(of: rootScope) { _, scope in
            guard ownsObservation, !suspended, let scope, let controller else { return }
            controller.updateRootScope(scope)
            controller.requestRefresh()
        }
        .onDisappear { if ownsObservation { controller?.stop() } }
    }
}

// MARK: - CallerApprovalRootCards

/// Root cards participate in the steering body's single scroll path.
private struct CallerApprovalRootCards: View {
    @Bindable var controller: CallerApprovalController
    let scope: WorkflowRootApprovalScope?

    var body: some View {
        let cards = controller.cards.filter { scope?.contains($0.request) ?? true }.map { card in
            var card = card
            card.canRespond = card.canRespond && !controller.isLoading && !controller.isSubmitting && !controller.isResponseQueued
            return card
        }
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            if !cards.isEmpty {
                Text(scope == nil ? "Orchestrator approval requests" : "Worker approval requests")
                    .font(.hf(.caption, weight: .semibold))
.foregroundStyle(Color.secondaryText)
            }
            ForEach(cards) { card in
                CallerApprovalRequestCard(model: card, respond: { controller.submit($0, requestID: card.id) },
                                          toggle: { controller.toggle(card.id) }, refresh: { controller.requestRefresh() },
                                          onFocusAcknowledged: { controller.acknowledgeFocus(requestID: card.id, token: $0) },
                                          pendingDisclosures: true, issuer: scope?.issuer(for: card.request))
                    .id(card.id)
            }
            if controller.nextCursor != nil {
                Button("More requests available · Load more") { controller.requestRefresh(loadMore: true) }
                    .disabled(controller.isLoading || controller.isSubmitting)
            }
            if controller.acquisitionLimited {
                Text("The request read reached its limit. Refresh to review the current requests.")
                    .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
                if controller.nextCursor == nil {
                    Button("Refresh") { controller.requestRefresh() }.disabled(controller.isLoading || controller.isSubmitting)
                }
            }
            if let error = controller.error { Text(error).font(.hf(.caption)).foregroundStyle(Color.failedRed).textSelection(.enabled) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(scope == nil ? "workflow-selected-approval" : "workflow-root-approvals")
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
    /// A complete request-local decision bar, measured independently of the panel's allocated height.
    var decisionBarMinimum: CGFloat = 0
    var regularDecisionBarMinimum: CGFloat = 0
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
    var viewIdentifier: String = Self.identifier

    /// Never the hit-test target, so it cannot take a click from anything it sits behind.
    final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier(viewIdentifier)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - CallerApprovalPinnedLayout

/// The panel's pinned layout: the cards scroll; the decision controls of each request awaiting a decision sit in a bar
/// under them. Each bar names its request when several cards are visually pending or several bars are present. A single bar
/// stays fixed. When stacked bars exceed the room they scroll, so every action stays reachable. The stack keeps the card viewport above
/// `minimumCardViewport` (or the awaiting cards' own height when that is smaller) and never below the tallest single bar.
/// The caller frames this view at the region height; the layout fills exactly that height and clips.
struct CallerApprovalPinnedLayout: View {
    @Environment(\.compactRootApprovalCoexistence) private var compactCoexistence
    @Bindable var controller: CallerApprovalController
    @State private var contentHeight: CGFloat = 0
    @State private var cardHeights: [String: CGFloat] = [:]
    @State private var measuredBarsHeight = WorkflowLayoutHeights()
    @State private var barHeights: [String: WorkflowLayoutHeights] = [:]

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
        let barsHeight = bars.isEmpty ? HfRadius.Metrics.zero : measuredBarsHeight.actual
        let spacing = HfRadius.Metrics.spacing8
        let padding = HfRadius.Metrics.spacing12
        // The cards awaiting a decision come first; only they (and the bars) are demanded.
        let awaitingContent: CGFloat? = awaiting.isEmpty ? nil
            : awaiting.reduce(2 * padding) { $0 + (cardHeights[$1.id] ?? 0) } + spacing * CGFloat(awaiting.count - 1)
        let barBottomPadding = compactCoexistence ? WorkflowCompactMetrics.compactBarBottom : WorkflowCompactMetrics.regularBarBottom
        let tallestBar = (bars.compactMap { barHeights[$0.id]?.actual }.max() ?? 0) + barBottomPadding
        let regularBarHeights = bars.compactMap { barHeights[$0.id]?.regular }
        let regularTallestBar = (regularBarHeights.max() ?? 0) + WorkflowCompactMetrics.regularBarBottom
        let regularBarMinimum = bars.isEmpty || regularBarHeights.count != bars.count ? 0
            : (bars.count > 1 ? regularTallestBar : measuredBarsHeight.regular)
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
                .background(CallerApprovalRegionFrameProbe(viewIdentifier: "approval-card-viewport-frame"))
                .clipped()
                // A visually pending card may have no actionable bar. Its presence still makes the label necessary.
                barStack(bars, viewport: barsShown, showsLabels: awaiting.count > 1 || bars.count > 1)
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
            natural: (awaitingContent ?? contentHeight) + barsHeight, awaitingDecision: !awaiting.isEmpty,
            decisionBarMinimum: bars.count > 1 ? tallestBar : barsHeight, regularDecisionBarMinimum: regularBarMinimum))
    }

    @ViewBuilder
    private func barStack(_ bars: [CallerApprovalCardModel], viewport: CGFloat, showsLabels: Bool) -> some View {
        if bars.count > 1 {
            ScrollView { barContent(bars, showsLabels: showsLabels) }
                .background(ScrollChrome())
                .frame(height: viewport)
                .clipped()
                .accessibilityIdentifier("approval-decision-bars")
        } else if bars.count == 1 {
            barContent(bars, showsLabels: showsLabels)
        } else {
            barContent([], showsLabels: false)
        }
    }

    private func barContent(_ bars: [CallerApprovalCardModel], showsLabels: Bool) -> some View {
        let barDelta = compactCoexistence ? 2 * (WorkflowCompactMetrics.regularInner - WorkflowCompactMetrics.compactInner) : 0
        let stackDelta = compactCoexistence && !bars.isEmpty
            ? CGFloat(bars.count) * barDelta + WorkflowCompactMetrics.regularBarBottom - WorkflowCompactMetrics.compactBarBottom : 0
        return VStack(spacing: HfRadius.Metrics.spacing8) {
            ForEach(bars) { bar in
                CallerApprovalDecisionBar(model: bar, showsLabel: showsLabels,
                                          respond: { controller.submit($0, requestID: bar.id) })
                    .onGeometryChange(for: WorkflowLayoutHeights.self) {
                        let height = $0.size.height
                        return WorkflowLayoutHeights(actual: height, regular: height + barDelta)
                    } action: { height in
                        if barHeights[bar.id] != height { barHeights[bar.id] = height }
                    }
            }
        }
        .padding(.horizontal, HfRadius.Metrics.spacing12)
        .padding(.bottom, bars.isEmpty ? HfRadius.Metrics.zero
            : (compactCoexistence ? WorkflowCompactMetrics.compactBarBottom : WorkflowCompactMetrics.regularBarBottom))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: WorkflowLayoutHeights.self) {
            let height = $0.size.height
            return WorkflowLayoutHeights(actual: height, regular: height + stackDelta)
        } action: { measuredBarsHeight = $0 }
    }
}

// MARK: - CallerApprovalDecisionBar

/// One request's pinned decision controls, styled like the pending card they belong to. When context is needed, a one-line
/// label names its request by tool and command. Middle truncation keeps differing endings visible. Help and accessibility
/// retain the full text.
struct CallerApprovalDecisionBar: View {
    @Environment(\.compactRootApprovalCoexistence) private var compactCoexistence
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
        .padding(.vertical, compactCoexistence ? WorkflowCompactMetrics.compactInner : WorkflowCompactMetrics.regularInner)
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
