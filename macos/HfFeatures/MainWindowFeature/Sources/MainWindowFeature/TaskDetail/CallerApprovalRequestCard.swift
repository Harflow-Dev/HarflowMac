import AppKit
import Foundation
import HfUI
import MonitorCore
import SwiftUI

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
    var pendingDisclosures = false
    var nativeInlineDisclosure = false
    var issuer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            if model.pending, !pendingDisclosures {
                Text(model.source).font(.hf(.secondary, weight: .semibold)).foregroundStyle(Color.warningFG)
            } else if nativeInlineDisclosure {
                VStack(alignment: .leading, spacing: 4) {
                    ApprovalDecisionButton(title: (model.expanded ? "▾ " : "▸ ") + model.barLabel,
                        enabled: true, identifier: "approval-disclosure-\(model.id)",
                        token: !model.canRespond || !model.expanded ? focusToken : nil,
                        isFocusReady: isFocusReady, action: toggle, acknowledge: acknowledgeFocus,
                        usesInlineStyle: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let issuer { Text(issuer).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                    Text(model.awaitingDecision ? "Awaiting decision" : settledStatus)
                        .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
                }
            } else {
                Button(action: toggle) {
                    HStack(alignment: .top) {
                        Image(systemName: model.expanded ? "chevron.down" : "chevron.right")
                        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                            Text(pendingDisclosures ? model.barLabel : model.action.title)
                            if pendingDisclosures, let issuer { Text(issuer).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
                            Text(pendingDisclosures && model.awaitingDecision ? "Awaiting decision" : settledStatus)
                                .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }
.buttonStyle(.plain)
                    .accessibilityIdentifier("approval-disclosure-\(model.id)")
            }
            if model.expanded || (model.pending && !pendingDisclosures) {
                detail
            } else if pendingDisclosures, let notice = model.notice {
                Text(notice).font(.hf(.caption)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            }
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
            if pendingDisclosures {
                actionFields
                if let reason = model.request.raw["decision_reason"]?.stringValue, !reason.isEmpty {
                    Text("Agent's stated reason").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    Text(verbatim: reason).font(.hf(.caption)).textSelection(.enabled)
                }
            } else {
                ApprovalDetailsScroll(identifier: "approval-details-\(model.id)",
                                      label: "Requested action details for \(model.action.title)",
                                      token: model.canRespond ? nil : focusToken,
                                      isFocusReady: isFocusReady, acknowledge: acknowledgeFocus) { actionFields }
                    .frame(maxHeight: 220)
.fixedSize(horizontal: false, vertical: true)
                if let reason = model.request.raw["decision_reason"]?.stringValue, !reason.isEmpty {
                    Text("Agent's stated reason").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    ScrollView { Text(verbatim: reason).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 96)
.font(.hf(.caption))
.fixedSize(horizontal: false, vertical: true)
                }
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

    private var actionFields: some View {
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
