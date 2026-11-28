import Testing

// MARK: - SkeletonMaskComparisonTests

/// Negative controls for the tolerance of the standard skeleton comparison: it must absorb one end-of-run flip per row
/// and reject everything else.
@Suite struct SkeletonMaskComparisonTests {
    private let base = ["....", "..###...##..", "............"]

    private func baseRows(_ row: String) -> [String] { ["....", row, "............"] }

    private func matches(_ row: String, against recorded: String = "..###...##..") -> Bool {
        SkeletonMaskComparison.rowsMatch(now: baseRows(row), base: baseRows(recorded))
    }

    @Test func givenIdenticalMasks_whenCompared_thenTheyMatch() {
        // given / when / then
        #expect(SkeletonMaskComparison.rowsMatch(now: base, base: base))
    }

    @Test func givenARunExtendedByOnePointAtItsEnd_whenCompared_thenItMatches() {
        // given / when / then
        #expect(matches("..####..##.."))
        #expect(matches(".####...##.."))
    }

    @Test func givenARunRetractedByOnePointAtItsEnd_whenCompared_thenItMatches() {
        // given / when / then
        #expect(matches("..##....##.."))
        #expect(matches("...##...##.."))
    }

    @Test func givenARunExtendedByTwoPoints_whenCompared_thenItFails() {
        // given / when / then
        #expect(!matches("..#####.##.."))
        #expect(!matches("#####...##.."))
    }

    @Test func givenAnInteriorFlip_whenCompared_thenItFails() {
        // given / when / then
        #expect(!matches("..#.#...##.."))
    }

    @Test func givenABarShiftedByOnePoint_whenCompared_thenItFails() {
        // given / when / then
        #expect(!matches("...###..##.."))
    }

    @Test func givenAnAddedRun_whenCompared_thenItFails() {
        // given / when / then
        #expect(!matches("..###...##.#"))
        #expect(!matches("..###.#.##.."))
    }

    @Test func givenARemovedRun_whenCompared_thenItFails() {
        // given
        let recorded = "..#....##..."

        // when / then
        #expect(!matches(".......##...", against: recorded))
    }

    @Test func givenARunJoinedToItsNeighbour_whenCompared_thenItFails() {
        // given
        let recorded = "..###.##...."

        // when / then
        #expect(!matches("..#######...", against: recorded))
    }

    @Test func givenTwoEndFlipsInOneRow_whenCompared_thenItFails() {
        // given / when / then
        #expect(!matches("..####..###."))
        #expect(!matches("..####...#.."))
    }

    @Test func givenEndFlipsInDifferentRows_whenCompared_thenEachRowMayFlipOnce() {
        // given
        let now = ["..####..", "..##....", "........"]
        let recorded = ["..###...", "..###...", "........"]

        // when / then
        #expect(SkeletonMaskComparison.rowsMatch(now: now, base: recorded))
    }

    @Test func givenDifferentRowCountsOrWidths_whenCompared_thenItFails() {
        // given / when / then
        #expect(!SkeletonMaskComparison.rowsMatch(now: ["..."], base: ["...", "..."]))
        #expect(!SkeletonMaskComparison.rowsMatch(now: ["..#"], base: ["..#."]))
    }

    @Test func givenEmptyRows_whenCompared_thenOnlyTwoEmptyRowsMatch() {
        // given / when / then
        #expect(matches("", against: ""))
        #expect(!matches("", against: "...."))
        #expect(!matches("....", against: ""))
    }

    @Test func givenMoreRowsThanTheBase_whenCompared_thenItFailsAndNamesTheLongerMask() {
        // given
        let now = ["..", "..", ".."]
        let recorded = ["..", ".."]

        // when / then
        #expect(!SkeletonMaskComparison.rowsMatch(now: now, base: recorded))
        #expect(SkeletonMaskComparison.mismatchedRows(now: now, base: recorded) == [0, 1, 2])
        #expect(!SkeletonMaskComparison.rowsMatch(now: ["..", ".."], base: []))
        #expect(!SkeletonMaskComparison.rowsMatch(now: [], base: [".."]))
        #expect(SkeletonMaskComparison.rowsMatch(now: [], base: []))
    }

    @Test func givenATwoPointRunRetractedToOne_whenCompared_thenItMatches() {
        // given / when / then — the run keeps one point, so it is shortened, not removed
        #expect(matches("..#.....", against: "..##...."))
        #expect(matches("...#....", against: "..##...."))
    }

    @Test func givenAFlipAtTheFirstOrLastPoint_whenCompared_thenItMatchesOnlyAtARunEnd() {
        // given / when / then
        #expect(matches("###.....", against: ".##....."))
        #expect(matches(".....###", against: ".....##."))
        #expect(!matches("#.##....", against: "..##...."))
        #expect(!matches("..##...#", against: "..##...."))
    }
}
