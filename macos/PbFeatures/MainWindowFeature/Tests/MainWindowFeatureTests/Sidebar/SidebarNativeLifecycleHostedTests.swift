@testable import MainWindowFeature
import MonitorCore
import PbRepository
import PbUI
import Testing

@MainActor
@Suite(.serialized)
struct SidebarNativeLifecycleHostedTests {
    @Test func givenAliasedRows_whenFadeIsReversedBeforeEnd_thenEveryOccurrenceRestores() throws {
                let rootA = SidebarItem.task(TaskRowModel(id: "root-a", backend: "codex", title: "Root A",
                                                           status: .completed, repoName: "repo", ageText: "1m",
                                                           indent: 0, hasChildren: true))
                let rootB = SidebarItem.task(TaskRowModel(id: "root-b", backend: "codex", title: "Root B",
                                                           status: .completed, repoName: "repo", ageText: "1m",
                                                           indent: 0, hasChildren: true))
                let childA = SidebarItem.task(TaskRowModel(id: "shared", backend: "codex", title: "Shared A",
                                                            status: .completed, repoName: "repo", ageText: "1m",
                                                            indent: 1))
                let childB = SidebarItem.task(TaskRowModel(id: "shared", backend: "codex", title: "Shared B",
                                                            status: .completed, repoName: "repo", ageText: "1m",
                                                            indent: 1))
                let expanded = presentation(items: [rootA, childA, rootB, childB], token: "alias")
                let initial = SidebarListReconciler.reconcile(expanded, previous: [])
                let aliases = initial.entries.filter { $0.id == "task:shared" }
                let identities = aliases.map(\.nativeID)
                let collapsed = presentation(items: [rootA, rootB], token: "alias")
                let fading = try #require(SidebarListReconciler.reconcile(
                    collapsed, previousInput: expanded, previous: initial.entries,
                    overlay: ["task:shared": SidebarNativeTransition(epoch: 3, fading: true, ended: false)]
                ))
                #expect(fading.entries.filter { $0.id == "task:shared" }.count == 2)
                let fadingAliases = fading.entries.filter { $0.id == "task:shared" }
                #expect(fadingAliases.allSatisfy { alias in alias.isFading })

                let restored = try #require(SidebarListReconciler.reconcile(
                    expanded, previousInput: collapsed, previous: fading.entries,
                    overlay: ["task:shared": SidebarNativeTransition(epoch: 3, fading: false, ended: false)]
                ))
                #expect(restored.entries.filter { $0.id == "task:shared" }.map(\.nativeID) == identities)
                #expect(restored.entries.filter { $0.id == "task:shared" }.allSatisfy { !$0.isFading })
    }

    @Test func givenRetainedTransition_whenReversedBeforeFinalPublication_thenIdentityAndIncarnationRemainStable() {
        // given
        let child = SidebarItem.task(TaskRowModel(id: "child", backend: "codex", title: "Child",
                                                   status: .completed, repoName: "repo", ageText: "1m"))
        let expanded = presentation(items: [.task(parent()), child])
        let initial = SidebarListReconciler.reconcile(expanded, previous: [])
        let fading = SidebarNativeTransition(epoch: 3, fading: true, ended: false)

        // when — the current input omits the child, then reverses before final removal.
        let collapsed = presentation(items: [.task(parent())])
        let closing = SidebarListReconciler.reconcile(collapsed, previousInput: expanded,
                                                       previous: initial.entries, overlay: ["task:child": fading])
        let restoredTransition = SidebarNativeTransition(epoch: 3, fading: false, ended: false)
        let reversed = SidebarListReconciler.reconcile(expanded, previousInput: collapsed,
                                                        previous: closing?.entries ?? initial.entries,
                                                        overlay: ["task:child": restoredTransition])

        // then — the retained row is restored without a fresh incarnation.
        let restored = reversed?.entries.first { $0.id == "task:child" }
        #expect(restored?.isFading == false)
        #expect(restored?.incarnation == 0)
    }

    @Test func givenEndedTransition_whenRowIsReaddedAtTheFinalEpoch_thenItReceivesAFreshIncarnation() {
        // given
        let child = SidebarItem.task(TaskRowModel(id: "child", backend: "codex", title: "Child",
                                                   status: .completed, repoName: "repo", ageText: "1m"))
        let expanded = presentation(items: [.task(parent()), child])
        let initial = SidebarListReconciler.reconcile(expanded, previous: [])
        let ended = SidebarNativeTransition(epoch: 4, fading: true, ended: true)

        // when — final removal is published, then the same public ID is reintroduced at epoch 4.
        let removed = presentation(items: [.task(parent())])
        let final = SidebarListReconciler.reconcile(removed, previousInput: expanded,
                                                     previous: initial.entries, overlay: ["task:child": ended])
        var readded = expanded
        readded.transitionEpoch = 4
        let fresh = SidebarListReconciler.reconcile(readded, previousInput: removed,
                                                     previous: final?.entries ?? [], overlay: ["task:child": ended])

        // then
        #expect(fresh?.entries.first(where: { $0.id == "task:child" })?.incarnation == 1)
        #expect(fresh?.entries.first(where: { $0.id == "task:child" })?.isFading == false)
    }

    @Test func givenEndedTransition_whenTombstoneIsPrunedBeforeReadd_thenBirthCounterStillAdvances() throws {
        let child = SidebarItem.task(TaskRowModel(id: "child", backend: "codex", title: "Child",
                                                   status: .completed, repoName: "repo", ageText: "1m"))
        let expanded = presentation(items: [.task(parent()), child])
        let initial = SidebarListReconciler.reconcile(expanded, previous: [])
        let initialEntry = try #require(initial.entries.first { $0.id == "task:child" })
        let initialIncarnation = initialEntry.incarnation
        let ended = SidebarNativeTransition(epoch: 4, fading: true, ended: true)
        let removedInput = presentation(items: [.task(parent())], transitionEpoch: 4)
        let removed = try #require(SidebarListReconciler.reconcile(
            removedInput, previousInput: expanded, previous: initial.entries,
            overlay: ["task:child": ended], birthCounter: initial.birthCounter
        ))
        let pruned = try #require(SidebarListReconciler.reconcile(
            removedInput, previousInput: removedInput, previous: removed.entries,
            overlay: [:], birthCounter: removed.birthCounter
        ))
        let readded = try #require(SidebarListReconciler.reconcile(
            expanded, previousInput: removedInput, previous: pruned.entries,
            overlay: [:], birthCounter: pruned.birthCounter
        ))

        let freshEntry = try #require(readded.entries.first { $0.id == "task:child" })
        let freshIncarnation = freshEntry.incarnation
        #expect(freshIncarnation > initialIncarnation)
    }

    private func parent() -> TaskRowModel {
        TaskRowModel(id: "parent", backend: "codex", title: "Parent", status: .completed,
                     repoName: "repo", ageText: "1m", hasChildren: true)
    }

    private func presentation(items: [SidebarItem], transitionEpoch: Int = 0,
                              token: String = "lifecycle") -> SidebarListPresentation {
        SidebarListPresentation(sections: [SidebarSection(bucket: .today, items: items)], workflowTitles: [],
                                workflowsExpanded: true, banner: nil, listError: nil, skeleton: false,
                                taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(),
                                emptyMessage: nil, fadingIDs: [], minimumRowHeight: 0,
                                historyRevision: 0, historyToken: token, transitionEpoch: transitionEpoch)
    }
}
