import Combine
import Foundation
@testable import HfRepository
import MonitorCore
import Testing

@Suite struct AgentUsageRepositoryImplTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "HfRepository.AgentUsage.\(UUID().uuidString)")! }

    @Test func givenAcknowledgementIsRecordedTwice_whenRepositoryRecords_thenItCountsOnceAndPersists() async {
        // given
        let store = defaults()
        let sut = AgentUsageRepositoryImpl(defaults: store)
        let identity = AgentUsageIdentity(backend: "claude", model: "sonnet")

        // when
        await sut.record(identity, acknowledgementID: "new-session:1")
        await sut.record(identity, acknowledgementID: "new-session:1")

        // then
        #expect(sut.snapshot.counts[identity] == 1)
        let restored = AgentUsageRepositoryImpl(defaults: store)
        await restored.record(identity, acknowledgementID: "new-session:1")
        #expect(restored.snapshot == sut.snapshot)
    }

    @Test func givenConcurrentSubmissions_whenRecorded_thenNoIncrementsAreLostAndAckNamespaceIsGlobal() async {
        // given
        let sut = AgentUsageRepositoryImpl(defaults: defaults())
        let identity = AgentUsageIdentity(backend: "codex", model: nil)

        // when — the same acknowledgement is deliberately submitted by two surfaces.
        await withTaskGroup(of: Void.self) { group in
            for id in ["workflow:1", "workflow:1", "new-session:1", "builder:1"] {
                group.addTask { await sut.record(identity, acknowledgementID: id) }
            }
        }

        // then
        #expect(sut.snapshot.counts[identity] == 3)
    }

    @Test func givenInvalidOrEmptyIdentity_whenRecorded_thenSnapshotRemainsEmpty() async {
        // given
        let sut = AgentUsageRepositoryImpl(defaults: defaults())

        // when
        await sut.record(AgentUsageIdentity(backend: "", model: "x"), acknowledgementID: "bad")
        await sut.record(AgentUsageIdentity(backend: "claude", model: nil), acknowledgementID: "")

        // then
        #expect(sut.snapshot.counts.isEmpty)
    }

    @Test func givenUsageCounts_whenRankingOptions_thenDuplicatesUnavailableModelsAndTiesAreDeterministic() {
        // given
        let claude = AgentUsageIdentity(backend: "claude", model: "opus")
        let codex = AgentUsageIdentity(backend: "codex", model: "gpt-5")
        let snapshot = AgentUsageSnapshot(counts: [claude: 2, codex: 2])

        // then
        #expect(snapshot.rankedBackends(["codex", "claude", "codex"]) == ["claude", "codex"])
        #expect(snapshot.rankedModels([
            ModelOption(value: "gpt-5", label: "GPT 5"),
            ModelOption(value: "opus", label: "Opus"),
            ModelOption(value: "opus", label: "Duplicate"),
            ModelOption(value: "", label: "Empty")
        ], backend: "claude")
.map(\.value) == ["opus", "gpt-5"])
    }

    @Test func givenPublisher_whenEqualSnapshotRepeats_thenItEmitsInitialAndChangesOnly() async {
        // given
        let sut = AgentUsageRepositoryImpl(defaults: defaults())
        var received: [AgentUsageSnapshot] = []
        let token = sut.snapshotPublisher().sink { received.append($0) }

        // when
        let identity = AgentUsageIdentity(backend: "vibe", model: nil)
        await sut.record(identity, acknowledgementID: "a")
        await sut.record(identity, acknowledgementID: "a")

        // then
        #expect(received.count == 2)
        #expect(received.last?.counts[identity] == 1)
        withExtendedLifetime(token) {}
    }
}
