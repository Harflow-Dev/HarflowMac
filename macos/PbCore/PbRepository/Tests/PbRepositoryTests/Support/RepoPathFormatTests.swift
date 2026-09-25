import Foundation
@testable import PbRepository
import Testing

/// Pins `RepoPathFormat.repo` — a deliberate duplicate of `PbUI.Format.repo`
/// (`Style.swift:134-137`), since `PbRepository` must not depend on `PbUI`. Expected values are
/// computed the same way `PbUI.Format.repo` computes them, so a future divergence between the two
/// copies is caught here rather than discovered in production.
@Suite struct RepoPathFormatTests {

    @Test func givenAPathUnderHome_whenFormatted_thenItIsAbbreviatedWithATilde() {
        // given
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

        // when
        let formatted = RepoPathFormat.repo(home + "/Code/polybridge")

        // then
        #expect(formatted == "~/Code/polybridge")
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
