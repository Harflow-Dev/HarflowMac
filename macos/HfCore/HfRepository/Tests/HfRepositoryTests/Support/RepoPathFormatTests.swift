import Foundation
@testable import HfRepository
import Testing

/// Pins `RepoPathFormat.repo` — a deliberate duplicate of `HfUI.Format.repo`
/// (`Style.swift:134-137`), since `HfRepository` must not depend on `HfUI`. Expected values are
/// computed the same way `HfUI.Format.repo` computes them, so a future divergence between the two
/// copies is caught here rather than discovered in production.
@Suite struct RepoPathFormatTests {

    @Test func givenAPathUnderHome_whenFormatted_thenItIsAbbreviatedWithATilde() {
        // given
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

        // when
        let formatted = RepoPathFormat.repo(home + "/Code/harflow")

        // then
        #expect(formatted == "~/Code/harflow")
    }

    @Test func givenAPathOutsideHome_whenFormatted_thenItIsReturnedUnchanged() {
        // given
        let path = "/opt/some/other/place"

        // when
        let formatted = RepoPathFormat.repo(path)

        // then
        #expect(formatted == path)
    }
}
