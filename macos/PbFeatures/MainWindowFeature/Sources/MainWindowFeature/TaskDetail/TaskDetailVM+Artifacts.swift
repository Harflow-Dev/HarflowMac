import Foundation
import MonitorCore
import Observation

// MARK: - ArtifactMemberModel

struct ArtifactMemberModel: Equatable, Identifiable, Sendable {
    static func isStandalone(_ member: TaskInfo) -> Bool {
        member.raw["workflow_builder"]?.boolValue != true
            && ["workflow_run_id", "workflow_node_id", "workflow_role"].allSatisfy { member.raw[$0] == nil || member.raw[$0] == .null }
    }

    let id: String
    var items: [TaskArtifact] = []
    var cursor: String?
    var hasMore = false
    var loaded = false
    var loading = false
    var message: String?
    var count: Int?
}

// MARK: - TaskDetailVM

extension TaskDetailVM {
    func recomputeArtifactMembers() {
        let eligible = conversationMembers.filter { member in
            !isWorkflowBuilder && ArtifactMemberModel.isStandalone(member)
        }
        let ids = Set(eligible.map(\.taskID))
        for id in artifactRequests.keys where !ids.contains(id) {
            artifactRequests.removeValue(forKey: id)?.cancel()
        }
        let next = eligible.map { member in
            artifactMembers.first { $0.id == member.taskID } ?? ArtifactMemberModel(id: member.taskID)
        }
        if artifactMembers != next { artifactMembers = next }
    }

    func didLoadArtifacts(taskID: String) {
        guard let index = artifactMembers.firstIndex(where: { $0.id == taskID }),
              !artifactMembers[index].loading else { return }
        let current = artifactMembers[index]
        let cursor = current.loaded && current.hasMore ? current.cursor : nil
        artifactMembers[index].loading = true
        artifactMembers[index].message = nil
        let generation = artifactGeneration
        artifactRequests[taskID] = Task { [weak self, useCase] in
            let result = await useCase.artifactPage(taskID: taskID, cursor: cursor)
            guard !Task.isCancelled, let self, artifactGeneration == generation,
                  let index = artifactMembers.firstIndex(where: { $0.id == taskID }) else { return }
            artifactRequests[taskID] = nil
            var next = artifactMembers[index]
            next.loading = false
            switch result {
            case .success(let page):
                guard page.taskID == taskID else {
                    next.message = "Artifact metadata unavailable: task identity mismatch."
                    artifactMembers[index] = next
                    return
                }
                if cursor == nil { next.items = [] }
                for item in page.items {
                    if let existing = next.items.firstIndex(where: { $0.id == item.id }) {
                        next.items[existing] = item
                    } else {
                        next.items.append(item)
                    }
                }
                next.loaded = true
                next.cursor = page.nextCursor
                next.hasMore = page.hasMore && page.nextCursor != cursor
                next.count = page.state == "available" ? page.count : nil
                next.message = page.state == "available" ? nil : "Artifact metadata unavailable."
            case .failure(let error):
                next.cursor = nil
                next.hasMore = false
                next.loaded = false
                next.count = nil
                next.message = "Artifact metadata unavailable. " + error.message
            }
            artifactMembers[index] = next
        }
    }
}
