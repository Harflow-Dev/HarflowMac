import Foundation
@testable import PbRepository
import Testing

@Suite struct GitChangesRepositoryImplTests {

    @Test func givenNoBaseCommit_whenAskedForChanges_thenTheNoBaselineLabelIsIncluded() async {
        // given — a stateless wrapper: no repo on disk needed to check the label passthrough, since
        // git itself will fail fast (no such directory) and the labels are computed independently.
        let sut = GitChangesRepositoryImpl(runner: StubProcessRunner { _ in .failure(.launchFailed(tool: "git", detail: "no such file")) })

        // when
        let changes = await sut.changes(repo: "/nonexistent-\(UUID().uuidString)", baseCommit: nil, startDirty: nil, environment: [:])

        // then
        #expect(changes.labels.contains { $0.contains("No baseline commit was recorded") })
        #expect(changes.comparedWithBase == false)
    }
}
