import Foundation
import MonitorCore

// MARK: - WorkflowArtifactModel

struct WorkflowArtifactModel: Equatable, Sendable {
    var runID: String?
    var executionID: String?
    var items: [TaskArtifact] = []
    var owners: [WorkflowArtifactOwner] = []
    var cursor: String?
    var hasMore = false
    var loaded = false
    var loading = false
    var message: String?
}

// MARK: - WorkflowVM artifact reads

extension WorkflowVM {
    func clearArtifacts() {
        artifactTask?.cancel()
        artifactTask = nil
        artifactGeneration = UUID()
        artifacts = WorkflowArtifactModel()
    }

    func prepareArtifacts(runID: String, executionID: String) {
        guard artifacts.runID != runID || artifacts.executionID != executionID else { return }
        artifactTask?.cancel()
        artifactTask = nil
        artifactGeneration = UUID()
        artifacts = WorkflowArtifactModel(runID: runID, executionID: executionID)
    }

    func loadArtifacts() {
        guard let runID = artifacts.runID, let executionID = artifacts.executionID, !artifacts.loading else { return }
        let cursor = artifacts.loaded && artifacts.hasMore ? artifacts.cursor : nil
        let generation = artifactGeneration
        artifacts.loading = true
        artifacts.message = nil
        artifactTask = Task { [weak self, useCase] in
            let result = await useCase.artifactPage(runID: runID, executionID: executionID, cursor: cursor)
            guard !Task.isCancelled, let self, artifactGeneration == generation else { return }
            artifactTask = nil
            var next = artifacts
            next.loading = false
            switch result {
            case .success(let page):
                guard page.runID == runID else {
                    next.message = "Unavailable: workflow identity mismatch"
                    artifacts = next
                    return
                }
                if cursor == nil { next.items = []; next.owners = [] }
                for item in page.items where !next.items.contains(where: { $0.id == item.id }) { next.items.append(item) }
                next.owners += page.owners
                next.cursor = page.nextCursor
                next.hasMore = page.hasMore
                next.loaded = true
                if page.state == "unavailable" { next.message = "Unavailable: " + (page.reason ?? "metadata could not be read") }
            case .failure:
                next.message = "Unavailable: artifact metadata could not be read"
            }
            artifacts = next
        }
    }
}
