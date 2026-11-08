//
//  TaskDetailVM+CallerApprovals.swift
//  MainWindowFeature
//
//  Starts and stops the caller approval controller for the shown task.
//

import Foundation
import HfRepository
import MonitorCore

// MARK: - Caller approvals

extension TaskDetailVM {

    func updateCallerApprovals(task: TaskInfo) {
        let relevant = task.raw["caller_approvals"]?.boolValue == true || task.raw["caller_write_approvals"]?.boolValue == true
            || (task.raw["approval_summary"]?["pending_count"]?.intValue ?? 0) > 0 || (task.awaitingDecisionCount ?? 0) > 0
            || callerApprovalController?.hasRetainedRequests(for: task.taskID) == true
        guard relevant else {
            callerApprovalController?.stop()
            callerApprovalController = nil
            return
        }
        if callerApprovalController == nil, let approvalUseCase = useCase.callerApprovalUseCase() {
            callerApprovalController = CallerApprovalController(useCase: approvalUseCase)
        }
        callerApprovalController?.setAwaitingDecisionCount(task.awaitingDecisionCount)
        callerApprovalController?.start(taskID: task.taskID, polls: task.status == .running)
    }
}
