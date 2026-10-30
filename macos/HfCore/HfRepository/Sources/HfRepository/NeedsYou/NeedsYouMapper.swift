import CryptoKit
import Foundation
import MonitorCore

// MARK: - NeedsYouMapper

/// Pure mapping from engine status values to Needs you items. Runs off the main actor.
enum NeedsYouMapper {
    /// A question entry plus whatever the mapper still needs from a source read.
    struct Candidate: Equatable {
        let entry: WorkflowPendingInput
        /// True when the entry belongs to a descendant and may need its source's structured usage-limit choices.
        let needsSourceRead: Bool
    }

    /// The root-level decision about what a ready root can contribute before any child read.
    struct RootPlan: Equatable {
        var questions: [Candidate] = []
        var recovery: NeedsYouItem?
        var interactionAvailable = false
    }

    static func shortID(_ id: String) -> String { String(id.prefix(8)) }

    static func ownership(_ state: WorkflowInteractionState) -> NeedsYouItem.Ownership {
        let owner: String = switch state.owner {
        case .monitor: "monitor"
        case .caller: "caller"
        case .unrecognized(let value): value
        }
        let handover = state.handover.map {
            NeedsYouItem.Handover(timestamp: $0.timestamp.map(Date.init(timeIntervalSince1970:)), reason: $0.reason, previousOwner: $0.previousOwner)
        }
        return .init(owner: owner, callerEnded: state.callerState == .dead, engineNote: state.reason, handover: handover)
    }

    static func startedBy(_ ownership: NeedsYouItem.Ownership) -> String {
        ownership.owner == "monitor" && ownership.handover == nil ? "Mac app" : "Original caller"
    }

    /// Chooses the questions and the recovery a ready root exposes. Callers have already established
    /// that the status is qualified and has `interaction_state`.
    static func plan(root status: WorkflowMonitorStatus, state: WorkflowInteractionState, names: [String: String]) -> RootPlan {
        var plan = RootPlan()
        guard !status.isTerminalOrCancelling, !status.settling, state.isAnswerableFromMonitor else { return plan }
        plan.interactionAvailable = true
        let rootID = status.runID
        let selected = status.inputDecisionID
        let resumeAllowed = status.resumeControl?.allowed == true
        var entries: [WorkflowPendingInput] = []
        if status.hasPendingInputsKey {
            entries = status.pendingInputs
        } else if let decision = selected, let question = status.inputQuestion, !question.isEmpty,
                  status.status == "needs_input" || (status.status == "needs_attention" && status.usageLimitRecovery?.decisionID == decision) {
            let sourceID = status.inputSourceRunID ?? rootID
            let path = status.inputSourcePath.isEmpty ? [rootID] : status.inputSourcePath
            entries = WorkflowPendingInput.synthetic(status: status, source: sourceID, path: path, decision: decision, question: question)
                .map { [$0] } ?? []
        }
        for entry in entries {
            // Only the root's selected checkpoint is gated by resume eligibility; the engine rechecks siblings on submit.
            if entry.decisionID == selected, !resumeAllowed { continue }
            plan.questions.append(Candidate(entry: entry, needsSourceRead: entry.workflowRunID != rootID))
        }
        if status.status == "needs_attention", selected == nil, resumeAllowed {
            plan.recovery = recovery(status: status, state: state, names: names)
        }
        return plan
    }

    private static func recovery(status: WorkflowMonitorStatus, state: WorkflowInteractionState, names: [String: String]) -> NeedsYouItem? {
        let rootID = status.runID
        let sourceID = status.raw["attention_source"]?.objectValue?["workflow_run_id"]?.stringValue ?? rootID
        let attention = status.pendingAttention.first { $0.status == "needs_attention" && $0.workflowRunID == sourceID }
        let reason = (attention?.reason).flatMap { $0.isEmpty ? nil : $0 } ?? status.attentionReason ?? ""
        guard !reason.isEmpty else { return nil }
        let own = ownership(state)
        let sourceName = attention.map { $0.workflowName.isEmpty ? names[$0.workflowRunID] ?? shortID($0.workflowRunID) : $0.workflowName }
            ?? status.name
        var path = pathTitles(entryPath: attention?.path ?? [], rootID: rootID, rootName: status.name, names: names, lastName: sourceName)
        if let node = attention?.nodeTitle, !node.isEmpty, node != path.last { path.append(node) }
        return NeedsYouItem(
            id: "attention:\(rootID):\(sourceID):\(fingerprint(reason))", kind: .recovery, rootRunID: rootID, sourceRunID: sourceID,
            runTitle: status.name.isEmpty ? shortID(rootID) : status.name, pathTitles: path, text: reason,
            ownership: own, startedBy: startedBy(own),
            waitingSince: (attention?.waitingSince ?? status.raw["updated_at"]?.doubleValue).map(Date.init(timeIntervalSince1970:)),
            canAddAttempts: status.additionalAttemptsControl?.allowed == true
        )
    }

    /// First 8 hex characters of the SHA-1 of the attention reason: a changed reason is a new checkpoint.
    static func fingerprint(_ reason: String) -> String {
        Insecure.SHA1.hash(data: Data(reason.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func question(
        candidate: Candidate, root status: WorkflowMonitorStatus, state: WorkflowInteractionState,
        names: [String: String], offered: [String]?
    ) -> NeedsYouItem {
        let entry = candidate.entry
        let rootID = status.runID
        let own = ownership(state)
        var path = pathTitles(entryPath: entry.path, rootID: rootID, rootName: status.name, names: names,
                              lastName: entry.workflowName.isEmpty ? nil : entry.workflowName)
        if !entry.nodeTitle.isEmpty, entry.nodeTitle != path.last { path.append(entry.nodeTitle) }
        return NeedsYouItem(
            id: "input:\(rootID):\(entry.decisionID)", kind: .question, rootRunID: rootID, sourceRunID: entry.workflowRunID,
            runTitle: status.name.isEmpty ? shortID(rootID) : status.name, pathTitles: path, text: entry.question,
            questionItems: entry.questionItems, offeredAnswers: offered, resumeHint: entry.isUsageLimit ? entry.resumeHint : nil,
            ownership: own, startedBy: startedBy(own), waitingSince: entry.waitingSince.map(Date.init(timeIntervalSince1970:)),
            decisionID: entry.decisionID
        )
    }

    /// Run ids from the engine's `path` resolved to names, with a short id when a name is unknown.
    static func pathTitles(entryPath: [String], rootID: String, rootName: String, names: [String: String], lastName: String?) -> [String] {
        var ids = entryPath
        if ids.first != rootID { ids.insert(rootID, at: 0) }
        return ids.enumerated().map { index, id in
            if id == rootID, !rootName.isEmpty { return rootName }
            if index == ids.count - 1, let lastName, !lastName.isEmpty { return lastName }
            if let name = names[id], !name.isEmpty { return name }
            return shortID(id)
        }
    }

    static func approval(request: CallerApprovalRequest, task: TaskInfo?) -> NeedsYouItem {
        let own = NeedsYouItem.Ownership(owner: request.interactionOwner?.rawValue ?? "", callerEnded: false, engineNote: "", handover: nil)
        let node = request.text("workflow_node_name")
        let title = request.text("task_title").isEmpty ? shortID(request.taskID) : request.text("task_title")
        let path = node.isEmpty ? [title] : [title, node]
        return NeedsYouItem(
            id: "approval:\(request.taskID):\(request.id)", kind: .approval, runTitle: title, pathTitles: path,
            text: actionLine(request), ownership: own, startedBy: startedBy(own),
            waitingSince: (request.raw["created_at"]?.doubleValue ?? task?.startedAt?.timeIntervalSince1970).map(Date.init(timeIntervalSince1970:)),
            approval: request, taskID: request.taskID
        )
    }

    /// "Tool: target", from the first readable input value of the requested action.
    static func actionLine(_ request: CallerApprovalRequest) -> String {
        let tool = request.raw["action"]?.objectValue?["tool_name"]?.stringValue ?? request.text("tool_name")
        let input = request.raw["action"]?.objectValue?["input"]?.objectValue ?? [:]
        let preferred = ["command", "file_path", "path", "url"].compactMap { input[$0]?.stringValue }.first
        let target = preferred ?? input.keys.sorted().compactMap { input[$0]?.stringValue }.first ?? ""
        let name = tool.isEmpty ? "Approval" : tool
        return target.isEmpty ? name : "\(name): \(target)"
    }
}

extension WorkflowPendingInput {
    /// Synthesizes the entry a plain root exposes through its single-checkpoint fields.
    static func synthetic(status: WorkflowMonitorStatus, source: String, path: [String], decision: String, question: String) -> WorkflowPendingInput? {
        var object: [String: JSONValue] = [
            "workflow_run_id": .string(source), "workflow_name": .string(status.inputSourceName ?? status.name), "decision_id": .string(decision),
            "question": .string(question), "path": .array(path.map(JSONValue.string)),
            "question_items": .array(status.inputQuestionItems.map(JSONValue.string))
        ]
        if let waitingSince = status.raw["updated_at"]?.doubleValue { object["waiting_since"] = .number(waitingSince, isInteger: false) }
        return WorkflowPendingInput(.object(object))
    }
}
