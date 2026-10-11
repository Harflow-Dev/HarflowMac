import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository
import PbTestUtilities
import Testing

@MainActor
@Suite(.serialized)
struct SidebarNativeAliasHostedTests {
    @Test func givenProducerTreeAndParallelGroupAliases_whenBuiltAndExpanded_thenBothOccurrencesRemainInProducerOrder() async throws {
        // given — the real presentation builder receives one tree producer and one parallel-group
        // producer for the same spawned children.
        let harness = SidebarVMTests().makeSUT()
        let helpers = SidebarVMTests()
        harness.sut.latestTasks = [
            helpers.task(id: "producer", status: "running"),
            helpers.task(id: "g1", status: "completed", group: "g", spawnedBy: "producer"),
            helpers.task(id: "g2", status: "completed", group: "g", spawnedBy: "producer")
        ]
        harness.sut.conversationIndex = ConversationIndex(harness.sut.latestTasks)
        harness.sut.recompute()
        await harness.sut.waitForPresentation()

        // when — expand the actual group producer through its existing VM action.
        harness.sut.didToggleExpansion(taskID: "group:g")
        await harness.sut.waitForPresentation()
        let items = harness.sut.sections.flatMap(\.items)
        let aliases = items.filter { $0.id == "task:g1" || $0.id == "task:g2" }

        // then — the tree and group producers each retain both children in their source order.
        #expect(aliases.map(\.id) == ["task:g1", "task:g2", "task:g1", "task:g2"])

        let presentation = SidebarListPresentation(
            sections: harness.sut.sections,
            workflowTitles: [], workflowsExpanded: true,
            banner: nil, listError: nil, skeleton: false,
            taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(),
            emptyMessage: nil, fadingIDs: [], minimumRowHeight: 0,
            historyRevision: 1, historyToken: "producer-alias"
        )
        let result = try #require(SidebarListReconciler.reconcile(presentation, previousInput: nil,
                                                                  previous: [], overlay: [:]))
        let displayAliases = result.entries.filter { $0.id == "task:g1" || $0.id == "task:g2" }

        #expect(displayAliases.count == 4)
        #expect(Set(displayAliases.map(\.displayID)).count == 4)
        #expect(Set(displayAliases.map(\.displayID.ownerID)) == ["task:producer", "group:g"])
        #expect(result.logicalDisplays["task:g1"]?.count == 2)
        #expect(result.logicalDisplays["task:g2"]?.count == 2)
    }

    @Test
    func givenExpandedRealAliases_whenEquivalentPresentationPollArrives_thenNativeAliasesStayQuiet() async throws {
        // given — both producers are mounted in the actual native outline.
        let fixture = try await NativeSidebarWindowFixture(aliasFixture: true)
        defer { fixture.close() }
        fixture.model.didToggleExpansion(taskID: "group:g")
        await fixture.model.waitForPresentation()
        await fixture.settle()
        let coordinator = try #require(fixture.outline.delegate as? SidebarNativeList.Coordinator)
        let displays = try #require(coordinator.logicalDisplays["task:g1"])
        let nativeIDs: [SidebarDisplayID: SidebarNativeIdentity] = Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            guard let nativeID = coordinator.boxesByID[display]?.entry.nativeID else { return nil }
            return (display, nativeID)
        })
        let hosts: [SidebarDisplayID: ObjectIdentifier] = Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            guard let host = coordinator.cells[display]?.host else { return nil }
            return (display, ObjectIdentifier(host))
        })
        #expect(nativeIDs.count == displays.count)
        #expect(hosts.count == displays.count)
        let before = (coordinator.measurementCount, coordinator.rootWriteCount,
                      coordinator.nativeOperationCount, coordinator.createdCellCount)

        // when — the VM republishes the same source snapshot, as the polling path does.
        fixture.model.recompute()
        await fixture.model.waitForPresentation()
        if let appliedInput = coordinator.appliedInput {
            coordinator.update(presentation: appliedInput, selection: coordinator.selection,
                                seenIDs: coordinator.seenIDs, environment: coordinator.environment)
        }
        await waitUntil(timeout: 5) {
            fixture.layout()
            return coordinator.reconciliation == nil && coordinator.detached == nil
        }

        // then — no native structure, cell roots, or measurements are attributed to the equal poll.
        #expect((coordinator.measurementCount, coordinator.rootWriteCount,
                 coordinator.nativeOperationCount, coordinator.createdCellCount) == before)
        #expect(displays.allSatisfy { coordinator.boxesByID[$0]?.entry.nativeID == nativeIDs[$0] })
        #expect(displays.allSatisfy { coordinator.cells[$0].map { ObjectIdentifier($0.host!) } == hosts[$0] })
        #expect(coordinator.logicalDisplays["task:g1"] == Set(displays))
    }
}
