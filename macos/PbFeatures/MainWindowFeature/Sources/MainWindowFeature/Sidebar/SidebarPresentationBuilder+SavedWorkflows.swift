import Foundation
import MonitorCore
import PbCommon
import PbUI

// MARK: - Sidebar SavedWorkflows presentation

extension SidebarPresentationBuilder {
    var savedWorkflows: [WorkflowRecord] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return workflowDefinitions.filter { record in
            query.isEmpty || "\(record.id) \(record.description)".lowercased().contains(query)
        }
.map { WorkflowRecord(raw: ["name": .string($0.id)]) }
    }

}
