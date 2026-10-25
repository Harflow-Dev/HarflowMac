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
    func supportsMonitorResponseForCallerApprovals() async throws -> Bool
}

extension CallerApprovalUseCase {
    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { false }
}

extension CallerApprovalRepository: CallerApprovalUseCase {}

// MARK: - CallerApprovalPanel

/// Workflows retain the run-sidebar location. Task detail owns its controller in the VM instead.
struct CallerApprovalPanel: View {
    var taskID: String?
    var workflowRunID: String?
    var polls = true
    @State private var controller: CallerApprovalController?
    @GlobalEnvironment(\.toolEnvironmentRepository) private var environment

    static func containsOptIn(_ value: JSONValue) -> Bool {
        if let object = value.objectValue {
            return object["caller_approvals"]?.boolValue == true || object.values.contains(where: containsOptIn)
        }
        return value.arrayValue?.contains(where: containsOptIn) ?? false
    }

    var body: some View {
        Group {
            if let controller, !controller.cards.isEmpty || controller.error != nil {
                CallerApprovalCard(controller: controller).padding(HfRadius.Metrics.spacing12)
            }
        }
        .task(id: "\(taskID ?? ""):\(workflowRunID ?? "")") {
            let value = CallerApprovalController(useCase: CallerApprovalRepository(environment: environment))
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

// MARK: - CallerApprovalCard

struct CallerApprovalCard: View {
    @Bindable var controller: CallerApprovalController
    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            ForEach(controller.cards) { card in
                CallerApprovalRequestCard(model: card, respond: { decision in
                    controller.submit(decision, requestID: card.id)
                }, toggle: { controller.toggle(card.id) })
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
    var onFocusAcknowledged: ((UUID) -> Void)?
    private enum FocusTarget: Hashable { case details, approve }
    @FocusState private var actionFocus: FocusTarget?

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
        .onChange(of: model.focusToken, initial: true) { _, token in
            guard let token else { return }
            Task { @MainActor in
                await Task.yield()
                guard model.focusToken == token else { return }
                actionFocus = model.canRespond && model.showsDecisionControls ? .approve : .details
                await Task.yield()
                guard model.focusToken == token else { return }
                onFocusAcknowledged?(token)
            }
        }
    }

    private var settledStatus: String {
        var values = [model.request.text("disposition")]
        values += CallerApprovalPresentation.decisionSummary(model.request)
        if model.request.text("responder") == "monitor" { values.append("Answered from Monitor") }
        if model.request.text("responder") == "caller" { values.append("Answered by the owning caller") }
        if model.request.text("decided_by") == "harflow" { values.append("Rejected by Harflow") }
        values.append("Delivery: " + model.request.text("delivery"))
        return values.joined(separator: " · ")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            Text(model.action.title).font(.hf(.secondary, weight: .semibold))
            context
            ScrollView {
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
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
.frame(maxHeight: 220)
.fixedSize(horizontal: false, vertical: true)
                .focusable(!model.canRespond)
.accessibilityIdentifier("approval-details-\(model.id)")
.accessibilityLabel("Requested action details for \(model.action.title)")
.focused($actionFocus, equals: .details)
            if let reason = model.request.raw["decision_reason"]?.stringValue, !reason.isEmpty {
                Text("Agent's stated reason").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                ScrollView { Text(verbatim: reason).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 96)
.font(.hf(.caption))
.fixedSize(horizontal: false, vertical: true)
            }
            if !model.pending {
                ForEach(CallerApprovalPresentation.decisionSummary(model.request), id: \.self) { Text($0).font(.hf(.caption)) }
                if model.request.text("responder") == "monitor" { Text("Answered from Monitor").font(.hf(.caption)) }
                Text("Delivery: \(model.request.text("delivery"))").font(.hf(.caption))
                Text("Observed execution: \(model.request.text("execution_outcome"))").font(.hf(.caption))
                if !model.request.text("system_rejection").isEmpty { Text(model.request.text("system_rejection")).font(.hf(.caption)).textSelection(.enabled) }
            }
            if let notice = model.notice {
                Text(notice).font(.hf(.caption)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            }
            if model.pending, model.showsDecisionControls {
                HStack {
                    Button(model.submitting ? "Submitting…" : "Approve once") { respond("approve") }
                        .focusable()
                        .focused($actionFocus, equals: .approve)
                        .accessibilityIdentifier("approval-approve-\(model.id)")
                    Button("Reject", role: .destructive) { respond("reject") }
                }.disabled(!model.canRespond)
            }
        }
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
            if !model.request.text("task_title").isEmpty { Text("Agent task: \(model.request.text("task_title"))") }
            if !model.request.text("workflow_node_name").isEmpty { Text("Workflow step: \(model.request.text("workflow_node_name"))") }
            Text("Working directory: \(model.request.text("cwd"))")
            Text("Access: \(model.request.text("freedom")) · Scope: \(model.request.text("scope"))")
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
