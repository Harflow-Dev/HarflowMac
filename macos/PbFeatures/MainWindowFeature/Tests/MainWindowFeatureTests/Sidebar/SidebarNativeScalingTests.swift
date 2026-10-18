import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository
import PbUI
import Testing

/// Large-input reconciliation checks. These exercise the detached edit script and complete-entry
/// equality without claiming that the enclosing SidebarView's own section comparison is O(1).
@MainActor
@Suite(.serialized)
struct SidebarNativeScalingTests {
    @Test(arguments: [100, 1_000, 10_000])
    func givenLargePresentation_whenEqualAndChangedInputsReconcile_thenOnlyExpectedEntriesChange(_ count: Int) throws {
        // given
        let initial = presentation(count: count)
        let first = SidebarListReconciler.reconcile(initial, previous: [])

        // when — an equal poll is reconciled against the applied snapshot.
        let equal = try #require(SidebarListReconciler.reconcile(initial, previousInput: initial,
                                                                  previous: first.entries, overlay: [:]))

        // then — no structural or content work is attributed to an equal poll.
        #expect(equal.quiet)
        #expect(equal.changedIDs.isEmpty)
        #expect(equal.operations.isEmpty)

        // when — one complete row changes while identity and order stay stable.
        let changedRow = TaskRowModel(id: "row-\(count / 2)", backend: "codex", title: "Updated title",
                                      status: .failed, repoName: "repo", ageText: "2m",
                                      detailLabel: "Updated detail", subTaskSummary: "1 sub-task")
        var changedRows = rows(count: count, start: 0)
        changedRows[count / 2] = changedRow
        let changed = presentation(rows: changedRows)
        let updated = try #require(SidebarListReconciler.reconcile(changed, previousInput: initial,
                                                                   previous: first.entries, overlay: [:]))

        // then — the complete changed entry is refreshed without inventing another identity.
        #expect(updated.changedIDs.contains(SidebarDisplayID(logicalID: "task:\(changedRow.id)")))
        #expect(updated.operations.isEmpty, "content-only mutation must not create structural operations")
        #expect(updated.entries.count == first.entries.count)
        #expect(applying(updated.operations, to: first.entries.map(\.nativeID)) == updated.entries.map(\.nativeID))
    }

    @Test func givenAppliedRows_whenAppendingAndReordering_thenEditScriptPreservesStableIdentity() throws {
        // given
        let initial = presentation(count: 100)
        let first = SidebarListReconciler.reconcile(initial, previous: [])
        let appendedRows = rows(count: 101, start: 0)
        let appended = presentation(rows: appendedRows)

        // when
        let page = try #require(SidebarListReconciler.reconcile(appended, previousInput: initial,
                                                                previous: first.entries, overlay: [:]))
        let reordered = presentation(rows: appendedRows.reversed())
        let moved = try #require(SidebarListReconciler.reconcile(reordered, previousInput: appended,
                                                                 previous: page.entries, overlay: [:]))

        // then
        #expect(page.operations.contains { if case .insert = $0 { true } else { false } }, "page operations=\(page.operations.count)")
        #expect(moved.operations.contains { if case .move = $0 { true } else { false } }, "move operations=\(moved.operations.count)")
        #expect(Set(moved.entries.map(\.id)).count == moved.entries.count)
        #expect(moved.entries.filter { $0.id.hasPrefix("task:") }.count == 101)
    }

    private func presentation(count: Int) -> SidebarListPresentation {
        presentation(rows: rows(count: count, start: 0))
    }

    private func presentation(rows: [TaskRowModel]) -> SidebarListPresentation {
        SidebarListPresentation(sections: [SidebarSection(bucket: .today, items: rows.map(SidebarItem.task))],
                                workflowTitles: [], workflowsExpanded: true, banner: nil, listError: nil,
                                skeleton: false, taskHistory: HistoryLoadingState(),
                                workflowHistory: HistoryLoadingState(), emptyMessage: nil, fadingIDs: [],
                                minimumRowHeight: 0, historyRevision: 4, historyToken: "scaling")
    }

    private func rows(count: Int, start: Int, excluding: String? = nil) -> [TaskRowModel] {
        (start ..< start + count).filter { excluding != "row-\($0)" }.map { index in
            TaskRowModel(id: "row-\(index)", backend: "codex", title: "Row \(index)", status: .completed,
                         repoName: "repo", ageText: "1m")
        }
    }

    private func applying(_ operations: [SidebarListReconciler.Operation],
                          to initial: [SidebarNativeIdentity]) -> [SidebarNativeIdentity] {
        var identities = initial
        for operation in operations {
            switch operation {
            case let .remove(index):
                identities.remove(at: index)
            case let .insert(index, identity):
                identities.insert(identity, at: index)
            case let .move(source, destination):
                let identity = identities.remove(at: source)
                identities.insert(identity, at: destination)
            }
        }
        return identities
    }
}
