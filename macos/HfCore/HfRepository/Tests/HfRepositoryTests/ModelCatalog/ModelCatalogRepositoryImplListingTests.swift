import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

// MARK: - Listings

extension ModelCatalogRepositoryImplTests {

    @Test func givenAnAvailableListing_whenListed_thenStateSourceCompletenessAndDefaultFlagsCarryThrough() async {
        // given
        let text = listing(source: "harness_cache", truncated: true, dropped: 3, rows: [
            Row(id: "auto", label: "Auto", isDefault: "true"), Row(id: "fast", label: "Fast", isDefault: "false"),
            Row(id: "other", label: "Other")
        ])
        let (sut, _) = makeSUT(answering: text)

        // when
        let result = await sut.listing(for: "opencode")

        // then
        #expect(result.state == .available)
        #expect(result.source == .harnessCache)
        #expect(result.truncated)
        #expect(result.droppedCount == 3)
        #expect(result.options.map(\.isDefault) == [true, false, false])
    }

    @Test func givenNotInstalled_whenListed_thenNoRowsEvenWhenDocumentedAliasesArrive() async {
        // given
        let text = listing(state: "not_installed", source: "documented_aliases", rows: [Row(id: "x/y", label: "X Y")])
        let (sut, _) = makeSUT(answering: text)

        // when
        let result = await sut.listing(for: "opencode")

        // then
        #expect(result.state == .notInstalled)
        #expect(result.source == .documentedAliases)
        #expect(result.options.isEmpty)
        #expect(await sut.models(for: "opencode").isEmpty)
    }

    @Test(arguments: [
        ("timeout", BackendModelListing.Reason.timeout), ("exit_nonzero", .exitNonzero), ("auth_required", .authRequired),
        ("unparseable", .unparseable), ("source_missing", .sourceMissing), ("output_ceiling", .outputCeiling),
        ("spawn_failed", .spawnFailed), ("future_reason", .unrecognized("future_reason"))
    ])
    func givenAnUnavailableListing_whenListed_thenTheReasonIsKept(_ wire: String, _ reason: BackendModelListing.Reason) async {
        // given
        let (sut, _) = makeSUT(answering: listing(state: "unavailable", reason: wire, source: nil))

        // when
        let result = await sut.listing(for: "opencode")

        // then
        #expect(result.state == .unavailable(reason))
        #expect(result.source == nil)
        #expect(result.options.isEmpty)
    }

    @Test func givenUnavailableWithoutAReason_whenListed_thenTheReasonIsNil() async {
        // given
        let (sut, _) = makeSUT(answering: listing(state: "unavailable", reason: nil))

        // then
        #expect(await sut.listing(for: "opencode").state == .unavailable(nil))
    }

    @Test func givenUnsupportedAndUnknownStates_whenListed_thenEachKeepsItsState() async {
        // given
        let (unsupported, _) = makeSUT(answering: listing(state: "unsupported"))
        let (unknown, _) = makeSUT(answering: listing(state: "future_state", rows: [Row(id: "x/y", label: "X")]))

        // then
        #expect(await unsupported.listing(for: "opencode").state == .unsupported)
        let result = await unknown.listing(for: "opencode")
        #expect(result.state == .unrecognized("future_state"))
        #expect(result.options.isEmpty)
    }

    @Test func givenAvailableWithZeroRows_whenListed_thenItIsAvailableAndEmpty() async {
        // given
        let (sut, _) = makeSUT(answering: listing(rows: []))

        // when
        let result = await sut.listing(for: "opencode")

        // then
        #expect(result.state == .available)
        #expect(result.options.isEmpty)
    }

    @Test func givenARefusalARunFailureOrNoRuntime_whenListed_thenTheListingIsUnreadable() async {
        // given
        let (refused, _) = makeSUT(answering: refusal(code: "agent_caller"))
        let (garbage, _) = makeSUT(answering: "not json")
        let (client, _) = client(capability: false) { _ in .success(stdout(listing())) }
        let (noCapability, _) = makeSUT(ctl: .success(client))
        let (noRuntime, _) = makeSUT(ctl: .failure(.notFound(tool: "harflow-ctl", searched: [])))

        // then
        #expect(await refused.listing(for: "opencode") == .unreadable)
        #expect(await garbage.listing(for: "opencode") == .unreadable)
        #expect(await noCapability.listing(for: "opencode") == .unreadable)
        #expect(await noRuntime.listing(for: "opencode") == .unreadable)
    }

    // MARK: - Listing cache

    @Test func givenAnAvailableListingWithRows_whenListedTwice_thenOneReadServesBoth() async {
        // given
        let (sut, runner) = makeSUT(answering: listing(rows: [Row(id: "a/b", label: "A B")]))

        // when
        let first = await sut.listing(for: "opencode")
        let second = await sut.listing(for: "opencode")

        // then
        #expect(first == second)
        #expect(commandCalls(runner).count == 1)
    }

    @Test(arguments: [
        listingDocument(state: "unavailable", reason: "timeout"), listingDocument(state: "not_installed"),
        listingDocument(state: "unsupported"), listingDocument(state: "future_state"), listingDocument(rows: []), "not json"
    ])
    func givenAnythingButAvailableWithRows_whenListedTwice_thenItIsNeverCached(_ document: String) async {
        // given
        let (sut, runner) = makeSUT(answering: document)

        // when
        _ = await sut.listing(for: "opencode")
        _ = await sut.listing(for: "opencode")

        // then
        #expect(commandCalls(runner).count == 2)
    }

    @Test func givenMixedModelsAndListingCallers_whenAsked_thenOneReadServesThemAll() async {
        // given
        let (sut, runner) = makeSUT(answering: listing(rows: [Row(id: "a/b", label: "A B")]))

        // when
        let models = await sut.models(for: "opencode")
        let result = await sut.listing(for: "opencode")

        // then
        #expect(models == result.options)
        #expect(commandCalls(runner).count == 1)
    }

    // MARK: - Refresh

    @Test func givenACachedListing_whenRefreshed_thenItReadsAgainAndTheNewAnswerIsCached() async {
        // given
        let reads = LockedBox(0)
        let (client, runner) = client { _ in
            let index = reads.value
            reads.mutate { $0 += 1 }
            return .success(stdout(listing(rows: [Row(id: index == 0 ? "old" : "new", label: "Row")])))
        }
        let (sut, _) = makeSUT(ctl: .success(client))
        _ = await sut.listing(for: "opencode")

        // when
        let refreshed = await sut.refreshListing(for: "opencode")
        let after = await sut.listing(for: "opencode")

        // then
        #expect(refreshed.options.map(\.value) == ["new"])
        #expect(after == refreshed)
        #expect(commandCalls(runner).count == 2)
    }

    @Test func givenAnUnavailableListing_whenRefreshedAfterItFinished_thenANewReadStarts() async {
        // given
        let reads = LockedBox(0)
        let (client, runner) = client { _ in
            let index = reads.value
            reads.mutate { $0 += 1 }
            return .success(stdout(index == 0 ? listing(state: "unavailable", reason: "timeout")
                    : listing(rows: [Row(id: "a/b", label: "A B")])))
        }
        let (sut, _) = makeSUT(ctl: .success(client))
        #expect(await sut.listing(for: "opencode").state == .unavailable(.timeout))

        // when
        let refreshed = await sut.refreshListing(for: "opencode")

        // then
        #expect(refreshed.state == .available)
        #expect(commandCalls(runner).count == 2)
    }

    /// A runner that answers the n-th `backend-models` call with `documents[n]` once `gates[n]` opens.
    private func gatedClient(documents: [String], gates: [AsyncGate]) -> (client: CtlClient, runner: StubProcessRunner) {
        let reads = LockedBox(0)
        return client { _ in
            let index = reads.value
            reads.mutate { $0 += 1 }
            if index < gates.count { gates[index].waitSync() }
            return .success(stdout(documents[min(index, documents.count - 1)]))
        }
    }

    @Test func givenTwoSimultaneousRefreshes_whenAnswered_thenOneReadServesBoth() async {
        // given
        let gate = AsyncGate()
        let (client, runner) = gatedClient(documents: [listing(rows: [Row(id: "a/b", label: "A B")])], gates: [gate])
        let (sut, _) = makeSUT(ctl: .success(client))

        // when
        async let first = sut.refreshListing(for: "opencode")
        async let second = sut.refreshListing(for: "opencode")
        await waitUntil { !commandCalls(runner).isEmpty }
        gate.open()
        let results = await [first, second]

        // then
        #expect(results[0] == results[1])
        #expect(commandCalls(runner).count == 1)
    }

    @Test func givenARefreshInFlight_whenAnotherReaderAsks_thenItJoinsTheRefresh() async {
        // given
        let gates = [AsyncGate(), AsyncGate()]
        let (client, runner) = gatedClient(
            documents: [listing(rows: [Row(id: "old", label: "Old")]), listing(rows: [Row(id: "new", label: "New")])], gates: gates
        )
        let (sut, _) = makeSUT(ctl: .success(client))
        async let original = sut.listing(for: "opencode")
        await waitUntil { commandCalls(runner).count == 1 }
        async let refreshed = sut.refreshListing(for: "opencode")
        await waitUntil { commandCalls(runner).count == 2 }

        // when
        async let third = sut.listing(for: "opencode")
        gates[1].open()
        gates[0].open()
        let results = await (original, refreshed, third)

        // then
        #expect(results.0.options.map(\.value) == ["old"])
        #expect(results.1.options.map(\.value) == ["new"])
        #expect(results.2 == results.1)
        #expect(commandCalls(runner).count == 2)
    }

    @Test(arguments: [true, false])
    func givenARefreshSupersedesARead_whenTheOriginalCompletesFirstOrLast_thenTheRefreshOwnsTheCache(_ originalFirst: Bool) async {
        // given
        let gates = [AsyncGate(), AsyncGate()]
        let (client, runner) = gatedClient(
            documents: [listing(state: "unavailable", reason: "timeout"), listing(rows: [Row(id: "new", label: "New")])], gates: gates
        )
        let (sut, _) = makeSUT(ctl: .success(client))
        async let original = sut.listing(for: "opencode")
        await waitUntil { commandCalls(runner).count == 1 }
        async let refreshed = sut.refreshListing(for: "opencode")
        await waitUntil { commandCalls(runner).count == 2 }

        // when
        if originalFirst {
            gates[0].open()
            _ = await original
            gates[1].open()
        } else {
            gates[1].open()
            _ = await refreshed
            gates[0].open()
        }
        _ = await (original, refreshed)
        let cached = await sut.listing(for: "opencode")

        // then
        #expect(cached.options.map(\.value) == ["new"])
        #expect(commandCalls(runner).count == 2)
    }

    @Test func givenARefreshSupersedesARead_whenTheOriginalWaiterStillWaits_thenItGetsTheOriginalAnswer() async {
        // given
        let gates = [AsyncGate(), AsyncGate()]
        let (client, runner) = gatedClient(
            documents: [listing(rows: [Row(id: "old", label: "Old")]), listing(rows: [Row(id: "new", label: "New")])], gates: gates
        )
        let (sut, _) = makeSUT(ctl: .success(client))
        async let original = sut.models(for: "opencode")
        await waitUntil { commandCalls(runner).count == 1 }
        async let refreshed = sut.refreshListing(for: "opencode")
        await waitUntil { commandCalls(runner).count == 2 }

        // when
        gates[0].open()
        gates[1].open()

        // then
        #expect(await original.map(\.value) == ["old"])
        #expect(await refreshed.options.map(\.value) == ["new"])
    }
}
