import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor @Suite
struct ResourceSlotsVMTests {
    @Test func givenRetainedReadingSnapshot_whenSetupRevalidates_thenSameRuntimePreservesItAndDifferentRuntimeResetsIt() async throws {
        // given
        let identity = UUID()
        let initial = try snapshot(identity: identity, title: "Original owner")
        let useCase = ResourceSlotsVMTestUseCase(snapshot: initial)
        let sut = ResourceSlotsVM(useCase: useCase, routing: ResourceSlotsVMTestRouting())
        sut.didAppear()
        defer { sut.didDisappear() }
        await waitUntil { sut.expandedResourceIDs.contains("sim") }
        try #require(sut.expandedResourceIDs.contains("sim"))
        sut.didToggleResource("sim")
        sut.readingState.beginAppearance()
        sut.readingState.update(.init(offset: 250, contentHeight: 2000, viewportHeight: 400), ready: true)
        sut.readingState.updateOwner(rowID: "sim/holder", groupID: "sim", frames: .init(viewport: CGRect(x: 0, y: 30, width: 100, height: 40),
                                                content: CGRect(x: 0, y: 280, width: 100, height: 40)))
        sut.readingState.prepareDeparture(ownerRowID: "sim/holder")
        let retainedAnchor = sut.readingState.retainedAnchor
        try #require(retainedAnchor?.rowID == "sim/holder")

        // when: a setup notification and changed metadata still belong to the same runtime.
        sut.runtimeChanged()
        await waitUntil { useCase.revalidations == 1 }
        try #require(useCase.revalidations == 1)
        useCase.send(try snapshot(identity: identity, title: "Updated owner"))
        await waitUntil { hasOwnerTitle("Updated owner", in: sut.presentation) }
        try #require(hasOwnerTitle("Updated owner", in: sut.presentation))

        // then
        #expect(sut.readingState.retainedOffset == 250)
        #expect(sut.readingState.retainedAnchor == retainedAnchor)
        #expect(!sut.expandedResourceIDs.contains("sim"), "Same-runtime revalidation must preserve disclosure choices")
        sut.didDisappear()
        sut.didAppear()
        #expect(sut.readingState.retainedOffset == 250, "Observation release alone does not replace the runtime")

        // when: equal owner IDs are supplied by a genuinely different runtime identity.
        useCase.send(try snapshot(identity: UUID(), title: "Replacement runtime owner"))
        await waitUntil { hasOwnerTitle("Replacement runtime owner", in: sut.presentation) }
        try #require(hasOwnerTitle("Replacement runtime owner", in: sut.presentation))

        // then
        #expect(sut.readingState.retainedOffset == 0)
        #expect(sut.readingState.retainedAnchor == nil)
        #expect(sut.readingState.focusedRowID == nil)
        #expect(sut.expandedResourceIDs.contains("sim"), "The new runtime starts a fresh initial disclosure choice")
    }

    private func hasOwnerTitle(_ title: String, in presentation: ResourceSlotsPresentation) -> Bool {
        guard case .ready(_, let groups) = presentation.state else { return false }
        return groups.flatMap(\.holders).contains { $0.title == title }
    }

    private func snapshot(identity: UUID, title: String) throws -> ResourceSlotsSnapshot {
        let owner = try ResourceSlotOwner(raw: ["kind": .string("task"), "task_id": .string("owner")])
        let inventory = try ResourceInventoryEntry(raw: [
            "name": .string("sim"), "capacity": .number(1),
            "holders": .array([.object([
                "reservation_id": .string("holder"), "names": .array([.string("sim")]), "state": .string("held"),
                "owner": .object(["kind": .string("task"), "task_id": .string("owner")]), "generation": .number(1),
                "enqueued_at": .string("2026-10-31T00:00:00+00:00"), "granted_at": .string("2026-10-31T00:00:01+00:00")
            ])]), "queue": .array([])
        ])
        let phase = try PhaseSlotsStatus(raw: [
            "leases": .array([]), "truncated": .bool(false),
            "configuration": .object(["epoch": .number(0), "names": .object([:])]),
            "service": .object(["state": .string("missing")])
        ])
        let metadata = ResourceSlotOwnerMetadata(owner: owner, title: title, destination: .task("owner"))
        return .init(phase: .ready, data: ResourceSlotsData(inventory: [inventory], phaseStatus: phase, owners: [owner: metadata]),
                     runtimeIdentity: identity)
    }
}

@MainActor
private final class ResourceSlotsVMTestUseCase: ResourceSlotsUseCase {
    private let subject: CurrentValueSubject<ResourceSlotsSnapshot, Never>
    private(set) var revalidations = 0
    var snapshot: ResourceSlotsSnapshot { subject.value }
    init(snapshot: ResourceSlotsSnapshot) { self.subject = CurrentValueSubject(snapshot) }
    func send(_ snapshot: ResourceSlotsSnapshot) { subject.send(snapshot) }
    func snapshotPublisher() -> AnyPublisher<ResourceSlotsSnapshot, Never> { subject.eraseToAnyPublisher() }
    func acquireObservation() async -> UUID { UUID() }
    func releaseObservation(_: UUID) async {}
    func refresh() async {}
    func runtimeChanged() async { revalidations += 1 }
}

@MainActor
private final class ResourceSlotsVMTestRouting: ResourceSlotsRouting {
    func openResourceSlotOwner(_: ResourceSlotOwnerMetadata.Destination) {}
}
