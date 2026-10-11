import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import Testing

@MainActor
@Suite(.serialized) struct SidebarNativeReconciliationTests {
    @Test func givenEqualPresentation_whenReconciled_thenNoRowsAreMarkedChanged() throws {
        let input = fixture()
        let first = try #require(SidebarListReconciler.reconcile(input, previousInput: nil,
                                                                  previous: [], overlay: [:]))
        let second = try #require(SidebarListReconciler.reconcile(input, previousInput: input,
                                                                  previous: first.entries, overlay: [:]))

        #expect(second.changedIDs.isEmpty)
        #expect(second.operations.isEmpty)
        #expect(second.entries.map(\.id) == first.entries.map(\.id))
    }

    @Test func givenContentChangesWithoutIdentityChanges_whenReconciled_thenTheCompleteEntryIsMarkedChanged() throws {
        let input = fixture()
        let first = SidebarListReconciler.reconcile(input, previous: [])
        var changed = input
        changed.sections = [SidebarSection(bucket: .today, items: [.task(TaskRowModel(
            id: "stable", backend: "codex", title: "Updated title", status: .failed,
            repoName: "repo", ageText: "2m", detailLabel: "Updated detail"
        ))])]
        let result = try #require(SidebarListReconciler.reconcile(changed, previousInput: input,
                                                                  previous: first.entries, overlay: [:]))
        let entry = result.entries.first { $0.id == "task:stable" }

        #expect(result.changedIDs.contains(SidebarDisplayID(logicalID: "task:stable")))
        #expect(entry?.id == "task:stable")
        #expect(entry?.content == .item(.task(TaskRowModel(
            id: "stable", backend: "codex", title: "Updated title", status: .failed,
            repoName: "repo", ageText: "2m", detailLabel: "Updated detail"
        ))))
    }

    @Test func givenRowsMoveBetweenSections_whenReconciled_thenStableIDsMoveWithoutBeingRecreated() throws {
        let row = SidebarItem.task(TaskRowModel(id: "stable", backend: "codex", title: "Stable", status: .running,
                                                 repoName: "repo", ageText: "1m"))
        let firstInput = fixture(sections: [SidebarSection(bucket: .running, items: [row]),
                                            SidebarSection(bucket: .today, items: [])])
        let first = SidebarListReconciler.reconcile(firstInput, previous: [])
        let movedInput = fixture(sections: [SidebarSection(bucket: .running, items: []),
                                            SidebarSection(bucket: .today, items: [row])])
        let moved = try #require(SidebarListReconciler.reconcile(movedInput, previousInput: firstInput,
                                                                previous: first.entries, overlay: [:]))

        #expect(moved.entries.contains { $0.id == "task:stable" })
        #expect(moved.operations.contains { if case .move = $0 { true } else { false } })
        #expect(!moved.changedIDs.contains(SidebarDisplayID(logicalID: "task:stable")))
        #expect(applying(moved.operations, to: first.entries.map(\.nativeID)) == moved.entries.map(\.nativeID))
    }

    @Test func givenHistoryAndSentinelInputs_whenReconciled_thenReadinessAndRevisionAreRepresented() throws {
        let base = fixture()
        let first = SidebarListReconciler.reconcile(base, previous: [])
        var changed = base
        changed.historyRevision = 7
        changed.historyToken = "new-token"
        changed.taskHistory.hasMore = true
        let result = try #require(SidebarListReconciler.reconcile(changed, previousInput: base,
                                                                  previous: first.entries, overlay: [:]))

        #expect(result.entries.contains { $0.id == "header:history" })
        #expect(result.entries.contains { $0.id == "history:tasks" })
        #expect(result.entries.contains { $0.id == "history:sentinel" })
        #expect(result.changedIDs.contains(SidebarDisplayID(logicalID: "history:tasks")))
    }

    @Test func givenTwoProducerAliasesWithTheSameLogicalChild_whenReconciled_thenBothDisplayIdentitiesRemainInOrder() throws {
        // given — two producer roots legitimately contain a child with the same logical ID.
        let rootA = TaskRowModel(id: "root-a", backend: "codex", title: "Root A", status: .running,
                                 repoName: "repo", ageText: "1m", indent: 0, hasChildren: true)
        let rootB = TaskRowModel(id: "root-b", backend: "codex", title: "Root B", status: .running,
                                 repoName: "repo", ageText: "1m", indent: 0, hasChildren: true)
        let childA = TaskRowModel(id: "shared-child", backend: "codex", title: "Child A", status: .completed,
                                  repoName: "repo", ageText: "1m", indent: 1)
        let childB = TaskRowModel(id: "shared-child", backend: "codex", title: "Child B", status: .completed,
                                  repoName: "repo", ageText: "1m", indent: 1)
        let input = fixture(sections: [SidebarSection(bucket: .today,
                                                       items: [.task(rootA), .task(childA), .task(rootB), .task(childB)])])

        // when
        let result = try #require(SidebarListReconciler.reconcile(input, previousInput: nil,
                                                                   previous: [], overlay: [:]))
        let aliases = result.entries.filter { $0.id == "task:shared-child" }

        // then — producer order and both owner-qualified native identities survive.
        #expect(aliases.count == 2)
        #expect(Set(aliases.map(\.displayID)).count == 2)
        #expect(aliases.map(\.displayID.ownerID) == ["task:root-a", "task:root-b"])
        #expect(result.logicalDisplays["task:shared-child"]?.count == 2)
        #expect(aliases.map(\.id) == ["task:shared-child", "task:shared-child"])

        // when — only the first producer's alias changes content.
        let changedChildA = TaskRowModel(id: "shared-child", backend: "codex", title: "Child A updated",
                                         status: .failed, repoName: "repo", ageText: "2m", indent: 1)
        let changedInput = fixture(sections: [SidebarSection(bucket: .today,
                                                              items: [.task(rootA), .task(changedChildA), .task(rootB), .task(childB)])])
        let changed = try #require(SidebarListReconciler.reconcile(changedInput, previousInput: input,
                                                                    previous: result.entries, overlay: [:]))

        // then — the edit remains owner-local and does not structurally reorder either alias.
        #expect(changed.operations.isEmpty)
        #expect(changed.changedIDs == [SidebarDisplayID(logicalID: "task:shared-child", ownerID: "task:root-a")])
    }

    @Test func givenRootMovesBucketWhileChildFades_whenReconciled_thenRetainedChildKeepsPreviousDisplayAnchor() throws {
        // given — a previously applied root/child tree whose child starts fading.
        let root = SidebarItem.task(TaskRowModel(id: "moving-root", backend: "codex", title: "Root",
                                                  status: .completed, repoName: "repo", ageText: "1m",
                                                  indent: 0, hasChildren: true))
        let child = SidebarItem.task(TaskRowModel(id: "moving-child", backend: "codex", title: "Child",
                                                   status: .completed, repoName: "repo", ageText: "1m",
                                                   indent: 1))
        let successor = SidebarItem.task(TaskRowModel(id: "successor", backend: "codex", title: "Successor",
                                                       status: .completed, repoName: "repo", ageText: "1m"))
        let previousInput = fixture(sections: [SidebarSection(bucket: .today, items: [root, child, successor]),
                                               SidebarSection(bucket: .earlier, items: [])])
        let previous = try #require(SidebarListReconciler.reconcile(previousInput, previousInput: nil,
                                                                     previous: [], overlay: [:]))
        let previousChild = try #require(previous.entries.first { $0.id == "task:moving-child" })

        // when — the root moves buckets while the child is omitted from the current input.
        let movedInput = fixture(sections: [SidebarSection(bucket: .earlier, items: [root]),
                                            SidebarSection(bucket: .today, items: [successor])])
        let moved = try #require(SidebarListReconciler.reconcile(
            movedInput, previousInput: previousInput, previous: previous.entries,
            overlay: ["task:moving-child": SidebarNativeTransition(epoch: 4, fading: true, ended: false)]
        ))

        // then — the retained occurrence uses its old owner/display identity and follows its root.
        let retained = try #require(moved.entries.first { $0.id == "task:moving-child" })
        let rootIndex = try #require(moved.entries.firstIndex { $0.id == "task:moving-root" })
        let childIndex = try #require(moved.entries.firstIndex { $0.id == "task:moving-child" })
        let successorIndex = try #require(moved.entries.firstIndex { $0.id == "task:successor" })
        let todayHeadingIndex = try #require(moved.entries.firstIndex {
            if case .heading("Today") = $0.content { return true }
            return false
        })
        #expect(retained.displayID == previousChild.displayID)
        #expect(retained.isFading)
        #expect(childIndex > todayHeadingIndex)
        #expect(childIndex < successorIndex)
        #expect(childIndex != rootIndex)
        #expect(moved.entries.filter { $0.displayID == previousChild.displayID }.count == 1)
        #expect(applying(moved.operations, to: previous.entries.map(\.nativeID)) == moved.entries.map(\.nativeID))
    }

    @Test func givenAliasPresentation_whenPolledWithoutChanges_thenReconciliationStaysQuiet() throws {
        let root = TaskRowModel(id: "root", backend: "codex", title: "Root", status: .running,
                                repoName: "repo", ageText: "1m", indent: 0, hasChildren: true)
        let child = TaskRowModel(id: "shared", backend: "codex", title: "Shared", status: .completed,
                                 repoName: "repo", ageText: "1m", indent: 1)
        let input = fixture(sections: [SidebarSection(bucket: .today,
                                                       items: [.task(root), .task(child), .task(root), .task(child)])])
        let first = try #require(SidebarListReconciler.reconcile(input, previousInput: nil,
                                                                  previous: [], overlay: [:]))
        let equal = try #require(SidebarListReconciler.reconcile(input, previousInput: input,
                                                                  previous: first.entries, overlay: [:]))

        #expect(equal.quiet)
        #expect(equal.operations.isEmpty)
        #expect(equal.entries == first.entries)
        #expect(first.logicalDisplays["task:shared"]?.count == 2)
    }

    private func fixture(sections: [SidebarSection] = [SidebarSection(bucket: .today, items: [
        .task(TaskRowModel(id: "stable", backend: "claude", title: "Stable", status: .running,
                           repoName: "repo", ageText: "1m"))
    ])]) -> SidebarListPresentation {
        SidebarListPresentation(sections: sections, workflowTitles: ["definition"], workflowsExpanded: true,
                                banner: nil, listError: nil, skeleton: false,
                                taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(),
                                emptyMessage: nil, fadingIDs: [], minimumRowHeight: 0,
                                historyRevision: 0, historyToken: "token")
    }

    private func applying(_ operations: [SidebarListReconciler.Operation],
                          to initial: [SidebarNativeIdentity]) -> [SidebarNativeIdentity] {
        var identities = initial
        for operation in operations {
            switch operation {
            case let .remove(index): identities.remove(at: index)
            case let .insert(index, identity): identities.insert(identity, at: index)
            case let .move(source, destination):
                let identity = identities.remove(at: source)
                identities.insert(identity, at: destination)
            }
        }
        return identities
    }
}
