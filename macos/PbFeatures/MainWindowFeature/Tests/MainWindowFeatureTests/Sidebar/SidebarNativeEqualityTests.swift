import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository
import PbUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarNativeEqualityTests {
    @Test func givenStableTaskIdentity_whenEachRenderedFieldChanges_thenCompleteEntryIsMarkedChanged() {
        // given
        let baseModel = TaskRowModel(id: "stable", backend: "codex", title: "Original", status: .running,
                                     repoName: "repo", ageText: "1m", detailLabel: "detail",
                                     subTaskSummary: "2 sub-tasks", startedAt: Date(timeIntervalSince1970: 1),
                                     durationSeconds: 60)
        let base = presentation(baseModel)
        let applied = SidebarListReconciler.reconcile(base, previous: [])

        let variants: [TaskRowModel] = [
            TaskRowModel(id: "stable", backend: "codex", title: "Updated", status: .running,
                         repoName: "repo", ageText: "1m", detailLabel: "detail",
                         subTaskSummary: "2 sub-tasks", startedAt: baseModel.startedAt,
                         durationSeconds: baseModel.durationSeconds),
            TaskRowModel(id: "stable", backend: "codex", title: "Original", status: .failed,
                         repoName: "repo", ageText: "1m", detailLabel: "detail",
                         subTaskSummary: "2 sub-tasks", startedAt: baseModel.startedAt,
                         durationSeconds: baseModel.durationSeconds),
            TaskRowModel(id: "stable", backend: "codex", title: "Original", status: .running,
                         repoName: "repo", ageText: "2m", detailLabel: "detail",
                         subTaskSummary: "2 sub-tasks", startedAt: baseModel.startedAt,
                         durationSeconds: 120),
            TaskRowModel(id: "stable", backend: "codex", title: "Original", status: .running,
                         repoName: "repo", ageText: "1m", detailLabel: "new detail",
                         subTaskSummary: "2 sub-tasks", startedAt: baseModel.startedAt,
                         durationSeconds: baseModel.durationSeconds),
            TaskRowModel(id: "stable", backend: "codex", title: "Original", status: .running,
                         repoName: "repo", ageText: "1m", detailLabel: "detail",
                         subTaskSummary: "3 sub-tasks", startedAt: baseModel.startedAt,
                         durationSeconds: baseModel.durationSeconds)
        ]

        // when / then
        for variant in variants {
            let result = SidebarListReconciler.reconcile(presentation(variant), previous: applied.entries)
            #expect(result.changedIDs == [SidebarDisplayID(logicalID: "task:stable")])
            #expect(result.entries.first(where: { $0.id == "task:stable" })?.content == .item(.task(variant)))
        }
    }

    private func presentation(_ model: TaskRowModel) -> SidebarListPresentation {
        SidebarListPresentation(sections: [SidebarSection(bucket: .today, items: [.task(model)])],
                                workflowTitles: [], workflowsExpanded: true, banner: nil, listError: nil,
                                skeleton: false, taskHistory: HistoryLoadingState(),
                                workflowHistory: HistoryLoadingState(), emptyMessage: nil, fadingIDs: [],
                                minimumRowHeight: 0, historyRevision: 0, historyToken: "equality")
    }
}
