import Foundation
@testable import MonitorCore
import Testing

/// Monitor piece 11: `LineageIndex` is the shared, build-once implementation behind
/// `Lineage.ancestors(of:in:)`/`children(of:in:)`/`siblings(of:in:)`/`cancelScope(of:in:)` — those
/// four statics' own existing behaviour is pinned by `LineageTests.swift`/`ConversationTests.swift`
/// (unchanged by this refactor). This file tests the type itself directly: that one instance answers
/// every kind of query correctly (not just the one the old per-call statics happened to be tested
/// through), and that `siblings(of:)` — new here, replacing `TaskDetailViewRepository`'s own
/// two-full-rebuild implementation — matches `Lineage.ancestors(of:in:).last` + `children(of:in:)`
/// exactly.
@Suite
struct LineageIndexTests {

    @Test
    func givenATaskTree_whenAskedForAncestorsAndChildren_thenTheyMatchTheSpawnedByChain() {
        // given — the same fixture `LineageTests`'s own equivalent test uses.
        let tasks = [
            task("r"), task("p", spawnedBy: "r", minute: 1), task("c", spawnedBy: "p", depth: 2, minute: 2),
            task("sib", spawnedBy: "p", depth: 2, minute: 3)
        ]
        // when
        let index = LineageIndex(tasks)
        // then
        #expect(index.ancestors(of: "c").map(\.taskID) == ["r", "p"])
        #expect(index.children(of: "p").map(\.taskID) == ["c", "sib"])
        #expect(index.ancestors(of: "r").isEmpty)
    }

    @Test
    func givenASiblingQuery_whenBuiltFromOneIndex_thenItMatchesTheAncestorsThenChildrenComposition() {
        // given
        let tasks = [
            task("r"), task("p", spawnedBy: "r", minute: 1), task("c", spawnedBy: "p", depth: 2, minute: 2),
            task("sib", spawnedBy: "p", depth: 2, minute: 3)
        ]
        // when
        let index = LineageIndex(tasks)
        // then — every child of the nearest ancestor, current task included.
        #expect(Set(index.siblings(of: "c").map(\.taskID)) == ["c", "sib"])
        #expect(index.siblings(of: "r").isEmpty, "a root task has no siblings")
        #expect(index.siblings(of: "r") == Lineage.siblings(of: "r", in: tasks))
        #expect(Set(index.siblings(of: "c").map(\.taskID)) == Set(Lineage.siblings(of: "c", in: tasks).map(\.taskID)))
    }

    @Test
    func givenAMissingParent_whenAskedForAncestors_thenTheChainStopsAtTheKnownRoot() {
        // given — "gone" is not present in `tasks` at all (retention, or never existed on disk).
        let tasks = [task("orphan", spawnedBy: "gone")]
        // when / then
        #expect(LineageIndex(tasks).ancestors(of: "orphan").isEmpty)
    }

    @Test
    func givenASpawnedByChain_whenComputingCancelScope_thenEveryDescendantIsIncluded() {
        // given — the same fixture `ConversationTests`'s own cancel-scope test uses.
        let tasks = [
            task("root", status: "running"), task("child", status: "running", spawnedBy: "root"),
            task("grandchild", status: "running", spawnedBy: "child")
        ]
        // when / then
        #expect(LineageIndex(tasks).cancelScope(of: "root") == ["root", "child", "grandchild"])
    }

    @Test
    func givenARootOnlyLinkedDescendant_whenComputingCancelScope_thenItIsIncludedEvenWithNoSpawnedByPath() {
        // given
        let tasks = [task("root", status: "running"), task("orphaned-but-rooted", status: "running", rootTaskID: "root")]
        // when / then
        #expect(LineageIndex(tasks).cancelScope(of: "root") == ["root", "orphaned-but-rooted"])
    }

    @Test
    func givenOneIndexReusedForSeveralMembers_whenQueried_thenEachQueryStillReflectsTheWholeListing() {
        // given — the shape `TaskDetailVM.recompute()` needs: several members, each queried for
        // ancestors/children/cancelScope off the SAME index (Plan review round 1, item 2) rather than
        // each query rebuilding its own map from `tasks`.
        let tasks = [
            task("p"), task("a", spawnedBy: "p", minute: 1), task("b", spawnedBy: "p", minute: 2),
            task("a-child", spawnedBy: "a", minute: 3)
        ]
        // when
        let index = LineageIndex(tasks)
        // then
        #expect(index.ancestors(of: "a").map(\.taskID) == ["p"])
        #expect(index.ancestors(of: "b").map(\.taskID) == ["p"])
        #expect(index.children(of: "a").map(\.taskID) == ["a-child"])
        #expect(index.children(of: "b").isEmpty)
        #expect(index.cancelScope(of: "a") == ["a", "a-child"])
    }
}
