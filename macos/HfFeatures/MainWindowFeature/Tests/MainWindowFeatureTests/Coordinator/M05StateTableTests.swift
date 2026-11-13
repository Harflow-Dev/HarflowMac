import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - M05StateTableTests

/// A consistency check of the state table. It reads no design files and proves nothing about pixels.
@Suite struct M05StateTableTests {

    @Test func givenTheTable_whenCountingStates_thenEachSuiteHasItsPinnedCount() {
        // given / when
        let counts = Dictionary(uniqueKeysWithValues: M05StateTable.Suite.allCases.map { ($0, M05StateTable.ids($0).count) })

        // then
        #expect(counts[.status] == 16)
        #expect(counts[.actionsTopBar] == 9)
        #expect(counts[.pane] == 11)
        #expect(counts[.changes] == 15)
        #expect(counts[.transcript] == 10)
        #expect(M05StateTable.designCommit == "4ff7d83")
    }

    @Test func givenTheTable_whenListingRenderedStates_thenIdsAreUniqueAndEqualApprovedMinusExclusions() {
        // given
        let rendered = M05StateTable.all.filter { $0.notRenderable == nil }.map(\.id)
        let excluded = Set(M05StateTable.exclusions.map(\.id))

        // when
        let union = Set(rendered)

        // then
        #expect(rendered.count == union.count, "a state id is mounted twice")
        #expect(union == M05StateTable.approved.subtracting(excluded))
        #expect(union.isDisjoint(with: excluded))
        #expect(rendered.count == 61)
    }

    @Test func givenEveryExclusionAndDeviation_whenRead_thenItCarriesAReason() {
        // given / when / then
        for exclusion in M05StateTable.exclusions { #expect(!exclusion.reason.isEmpty, "\(exclusion.id)") }
        for family in M05StateTable.excludedFamilies { #expect(!family.reason.isEmpty, "\(family.prefix)") }
        for entry in M05StateTable.all {
            #expect(entry.deviation?.isEmpty != true, "\(entry.id)")
            #expect(entry.notRenderable?.isEmpty != true, "\(entry.id)")
            #expect(entry.designRoute == "task/" + entry.id)
            #expect(entry.designFile.hasPrefix("v2/scripts/"))
            #expect(!entry.recipe.isEmpty)
        }
        for entry in M05StateTable.all where entry.notRenderable != nil {
            #expect(M05StateTable.exclusions.contains { $0.id == entry.id }, "\(entry.id) is not renderable but not an exclusion")
        }
    }
}
