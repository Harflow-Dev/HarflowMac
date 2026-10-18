import Foundation
@testable import MonitorCore
import Testing

@Suite
struct TreeGuideTests {
    @Test
    func givenASingleRoot_whenFlattenedWithGuides_thenItHasNoGuides() {
        // given
        let tasks = [task("root")]
        let sections = Lineage.sections(tasks)
        let root = sections.recent[0]

        // when
        let rows = root.flattenedWithGuides()

        // then
        #expect(rows.map(\.indent) == [0])
        #expect(rows.map(\.guides) == [[]])
    }

    @Test
    func givenARootWithTwoChildren_whenFlattenedWithGuides_thenTheFirstBranchesAndTheSecondIsLast() {
        // given
        let tasks = [task("root"), task("a", spawnedBy: "root", minute: 1), task("b", spawnedBy: "root", minute: 2)]
        let sections = Lineage.sections(tasks)
        let root = sections.recent[0]

        // when
        let rows = root.flattenedWithGuides()

        // then
        #expect(rows.map(\.node.id) == ["root", "a", "b"])
        #expect(rows.map(\.guides) == [[], [.branch], [.last]])
    }

    @Test
    func givenThreeLevels_whenFlattenedWithGuides_thenContinuationLinesOnlyDrawWhereALaterSiblingExists() {
        // given — "a" (first of two root children) has a child "a-only"; the continuation column
        // for "a"'s level must draw only while "a" itself still has a later sibling ("b") to reach.
        let tasks = [
            task("root"),
            task("a", spawnedBy: "root", minute: 1),
            task("a-only", spawnedBy: "a", minute: 2),
            task("b", spawnedBy: "root", minute: 3)
        ]
        let sections = Lineage.sections(tasks)
        let root = sections.recent[0]

        // when
        let rows = root.flattenedWithGuides()

        // then
        #expect(rows.map(\.node.id) == ["root", "a", "a-only", "b"])
        #expect(rows.map(\.indent) == [0, 1, 2, 1])
        // "a" branches (a later sibling "b" follows); "a-only" continues the line through "a"'s
        // column (because "a" has a later sibling) and is itself the last (only) child, so `.last`.
        #expect(rows.map(\.guides) == [[], [.branch], [.continuation, .last], [.last]])
    }

    @Test
    func givenAThreeLevelTreeWhereTheBranchHasNoLaterSibling_whenFlattenedWithGuides_thenTheColumnIsBlank() {
        // given — "a" is the only (and so last) child of "root"; a deeper descendant's ancestor
        // column for "a"'s level must be blank, not a continuation line, since "a" has no later
        // sibling to reach down to.
        let tasks = [task("root"), task("a", spawnedBy: "root", minute: 1), task("a-only", spawnedBy: "a", minute: 2)]
        let sections = Lineage.sections(tasks)
        let root = sections.recent[0]

        // when
        let rows = root.flattenedWithGuides()

        // then
        #expect(rows.map(\.node.id) == ["root", "a", "a-only"])
        #expect(rows.map(\.guides) == [[], [.last], [.blank, .last]])
    }

    @Test
    func givenARetentionOrphanedChild_whenFlattenedWithGuides_thenItBecomesARootWithNoGuides() {
        // given — the parent ("gone") is not in the listing, so `Lineage.sections` makes "orphan" a
        // root of its own tree (mirrors `LineageTests`'s own orphan case).
        let tasks = [task("orphan", status: "running", spawnedBy: "gone")]

        // when
        let sections = Lineage.sections(tasks)
        let rows = sections.running[0].flattenedWithGuides()

        // then
        #expect(rows.map(\.node.id) == ["orphan"])
        #expect(rows.map(\.guides) == [[]])
    }
}
