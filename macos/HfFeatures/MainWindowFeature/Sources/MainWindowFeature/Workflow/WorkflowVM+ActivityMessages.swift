import Foundation
import MonitorCore

// MARK: - WorkflowVM Activity messages

extension WorkflowVM {
    var activityMessageItems: [WorkMessageQueue.Item] {
        let target = activityMessageTarget
        guard let runID = target.runID else { return [] }
        let raw = runID == selectedRun?.id ? selectedRun?.raw
            : activityMessageSnapshotRunID == runID ? activityMessageSnapshot : nil
        let messages = raw?["messages"]?.arrayValue?.filter(target.includes) ?? []
        return WorkMessageQueue.items(raw: ["messages": .array(messages)], source: .workflowRun)
    }

    func refreshActivityMessageState() async {
        let target = activityMessageTarget
        guard let runID = target.runID, runID != selectedRun?.id else {
            if activityMessageReadError != nil { activityMessageReadError = nil }
            return
        }
        do {
            let result = try await builderCommand("status", options: ["--monitor-view"], positionals: [runID])
            guard !Task.isCancelled, activityMessageTarget == target else { return }
            let raw = result["run"]?.objectValue ?? result
            guard raw["workflow_run_id"]?.stringValue == runID else { throw WorkflowUIError.missingRun }
            if activityMessageSnapshot != raw { activityMessageSnapshot = raw }
            if activityMessageSnapshotRunID != runID { activityMessageSnapshotRunID = runID }
            if activityMessageReadError != nil { activityMessageReadError = nil }
        } catch {
            guard !Task.isCancelled, activityMessageTarget == target else { return }
            let message = "Queued messages could not be refreshed: " + Self.message(error)
            if activityMessageReadError != message { activityMessageReadError = message }
        }
    }

    func submitActivityMessage(_ text: String, now: Bool) -> Bool {
        let target = activityMessageTarget
        guard !steeringOwnsComposer || (steeringFailedQueue && !now), !isBusy, !messagingUnsupported,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let runID = target.runID, target.unavailableReason == nil else { return false }
        let options = ["--monitor", "--delivery=\(now ? "now" : "queue")"]
            + (target.taskID.map { ["--task-id=\($0)"] } ?? [])
        let onFailure = makeMessagingFailureHandler()
        perform { [weak self] in
            guard let self else { return }
            let result: [String: JSONValue]
            do {
                result = try await builderCommand("send", options: options, positionals: [runID, text])
            } catch {
                onFailure(error)
                throw error
            }
            if activityMessageTarget == target { errorText = WorkMessageOutcome.notice(result) }
            if let id = result["message_id"]?.stringValue, let note = WorkMessageBubble.refusalNote(in: result) {
                messageNotes[id] = note
            }
            await refresh()
        }
        return true
    }

    func cancelActivityMessage(_ messageID: String) {
        let target = activityMessageTarget
        guard !isBusy, let runID = target.runID, target.unavailableReason == nil else { return }
        perform { [weak self] in
            guard let self else { return }
            _ = try await builderCommand("cancel-message", options: ["--monitor"], positionals: [runID, messageID])
            if activityMessageTarget == target { errorText = "Queued message cancelled." }
            await refresh()
        }
    }
}
