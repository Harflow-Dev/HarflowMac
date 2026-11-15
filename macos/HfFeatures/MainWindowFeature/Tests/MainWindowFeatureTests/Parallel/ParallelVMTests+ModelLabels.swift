import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

extension ParallelVMTests {
    /// The engine's model lists by backend and every backend asked, in order. Answers are read at call time.
    final class CatalogStub {
        var answers: [String: [ModelOption]] = [:]
        var calls: [String] = []
    }

    /// Answers `modelOptions(backend:)` from `catalog` (nothing by default) and records every backend asked.
    static func stubCatalog(_ useCase: MockParallelUseCase, _ catalog: CatalogStub) {
        given(useCase).modelOptions(backend: .any).willProduce { backend in
            catalog.calls.append(backend)
            return catalog.answers[backend] ?? []
        }
    }

    /// A catalog whose requests are answered by the test, in any order.
    @MainActor final class CatalogGate {
        private var held: [CheckedContinuation<[ModelOption], Never>] = []
        var asked: Int { held.count }

        func ask() async -> [ModelOption] {
            await withCheckedContinuation { held.append($0) }
        }

        func answer(_ index: Int, _ options: [ModelOption]) { held[index].resume(returning: options) }
    }

    /// Holds the first build open and records whether it was cancelled meanwhile.
    @MainActor final class BuildGate {
        private var blocked: CheckedContinuation<Void, Never>?
        private(set) var holds = 0
        private(set) var cancelled = false
        var started: Bool { holds > 0 }

        func hold() async {
            holds += 1
            guard holds == 1 else { return }
            await withCheckedContinuation { blocked = $0 }
            cancelled = Task.isCancelled
        }

        func release() { blocked?.resume(); blocked = nil }
    }

    private func captions(_ sut: ParallelVM) -> [String] { sut.columns.map(\.caption) }

    private func drain() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    // MARK: - Requests

    @Test func givenLanesOfTwoBackends_whenTheScreenAppears_thenTheCatalogIsAskedOncePerBackend() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        let tasks = [task(id: "a", backend: "claude", model: "opus"), task(id: "b", backend: "claude", model: "sonnet"),
                     task(id: "c", backend: "codex", model: "gpt")]
        for item in tasks { harness.tasksBox.value[item.taskID] = item }
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }

        // when
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 3 && harness.sut.isPresentationSettled }
        await waitUntil { catalog.calls.count == 2 }
        harness.tasksSubject.send(tasks)
        harness.busySubject.send([])
        await drain()

        // then
        #expect(catalog.calls.sorted() == ["claude", "codex"])
    }

    @Test func givenABackendAlreadyAsked_whenANewBackendJoins_thenOnlyTheNewBackendIsAsked() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        let first = task(id: "a", backend: "claude", model: "opus")
        harness.tasksBox.value["a"] = first
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([first])
        await waitUntil { catalog.calls == ["claude"] }

        // when
        let second = task(id: "b", backend: "codex", model: "gpt")
        harness.tasksBox.value["b"] = second
        harness.tasksSubject.send([first, second])
        await waitUntil { catalog.calls.count == 2 }
        await drain()

        // then
        #expect(catalog.calls == ["claude", "codex"])
    }

    @Test func givenTheGraphInspector_whenLanesAppear_thenTheCatalogIsNeverAsked() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        let inspector = harness.sut.makeWorkflowActivity()
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        inspector.didAppear()
        defer { inspector.didDisappear() }

        // when
        harness.tasksSubject.send([running])
        await waitUntil { inspector.columns.count == 1 && inspector.isPresentationSettled }
        await drain()

        // then
        #expect(catalog.calls.isEmpty)
        #expect(inspector.columns.first?.chrome == .inspector)
    }

    // MARK: - Captions

    @Test func givenARawModel_whenTheLabelArrivesLater_thenTheCaptionIsRefreshedFromTheCatalog() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "claude-opus-5-5", label: "Opus 5.5")]
        let running = task(id: "a", model: "claude-opus-5-5")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }

        // when
        harness.tasksSubject.send([running])

        // then
        await waitUntil { harness.sut.columns.first?.caption == "Claude · Opus 5.5" }
        #expect(captions(harness.sut) == ["Claude · Opus 5.5"])
    }

    @Test func givenAModelMissingFromTheCatalog_whenTheAnswerArrives_thenTheRawIdStays() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        let running = task(id: "a", model: "haiku")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }

        // when
        harness.tasksSubject.send([running])
        await waitUntil { catalog.calls.count == 1 }
        await drain()

        // then
        #expect(captions(harness.sut) == ["Claude · haiku"])
    }

    @Test func givenALaneWithoutAModel_whenTheAnswerArrives_thenItsCaptionIsTheHarnessOnly() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "", label: "Default"), ModelOption(value: "opus", label: "Opus 5.5")]
        let running = task(id: "a")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }

        // when
        harness.tasksSubject.send([running])
        await waitUntil { catalog.calls.count == 1 }
        await drain()

        // then
        #expect(captions(harness.sut) == ["Claude"])
    }

    @Test func givenResidentAndNonResidentLanes_whenTheLabelArrives_thenEveryLanesCaptionIsRefreshed() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        harness.sut.updateViewport(offset: 0, width: ParallelTestGeometry.laneStride * 2)
        let tasks = (0 ..< 8).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0)), model: "opus") }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }

        // when
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 8 && captions(harness.sut).allSatisfy { $0 == "Claude · Opus 5.5" } }

        // then
        #expect(harness.sut.residentColumnCount == 2)
        #expect(harness.sut.columns.filter { !$0.isResident }.count == 6)
        #expect(captions(harness.sut).allSatisfy { $0 == "Claude · Opus 5.5" })
    }

    @Test func givenARetainedLane_whenTheViewportMovesAwayAndTheLabelChanges_thenItsCaptionStillFollowsTheCatalog() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        harness.sut.updateViewport(offset: 0, width: ParallelTestGeometry.laneStride * 2)
        let tasks = (0 ..< 8).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0)), model: "opus") }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 8 && captions(harness.sut).allSatisfy { $0 == "Claude · Opus 5.5" } }
        harness.sut.updateViewport(offset: ParallelTestGeometry.laneStride * 6, width: ParallelTestGeometry.laneStride * 2)
        await waitUntil { harness.sut.isPresentationSettled }

        // when: the engine now answers with a renamed label.
        harness.sut.applyModelLabels([ModelOption(value: "opus", label: "Opus 5.6")], backend: "claude")

        // then
        #expect(captions(harness.sut).allSatisfy { $0 == "Claude · Opus 5.6" })
    }

    // MARK: - Publishing

    @Test func givenLoadedLabels_whenTheSameLabelsAreAppliedAgain_thenNothingIsRepublished() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        let options = [ModelOption(value: "opus", label: "Opus 5.5")]
        catalog.answers["claude"] = options
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.columns.first?.caption == "Claude · Opus 5.5" }
        await waitUntil { harness.sut.isPresentationSettled }
        let writes = harness.sut.presentationWriteCount

        // when: same label with different effort metadata, then the identical answer again.
        harness.sut.applyModelLabels([ModelOption(value: "opus", label: "Opus 5.5", effortLevels: ["low"])], backend: "claude")
        harness.sut.applyModelLabels(options, backend: "claude")

        // then
        #expect(harness.sut.presentationWriteCount == writes)
    }

    @Test func givenLoadedLabels_whenAChangedLabelIsApplied_thenTheColumnsArePublishedOnce() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.columns.first?.caption == "Claude · Opus 5.5" }
        await waitUntil { harness.sut.isPresentationSettled }
        let writes = harness.sut.presentationWriteCount

        // when
        harness.sut.applyModelLabels([ModelOption(value: "opus", label: "Opus 5.6")], backend: "claude")

        // then
        #expect(harness.sut.presentationWriteCount == writes + 1)
        #expect(harness.sut.columns.first?.caption == "Claude · Opus 5.6")
    }

    @Test func givenAnEmptyAnswerForALoadedBackend_whenApplied_thenTheKnownLabelsAreKept() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.columns.first?.caption == "Claude · Opus 5.5" }

        // when
        harness.sut.applyModelLabels([], backend: "claude")

        // then
        #expect(harness.sut.columns.first?.caption == "Claude · Opus 5.5")
        #expect(harness.sut.modelLabels.labels["claude"] == ["opus": "Opus 5.5"])
    }

    @Test func givenDuplicateValuesInAnAnswer_whenApplied_thenTheFirstLabelWins() async {
        // given
        let harness = makeSUT()
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.columns.count == 1 }

        // when
        harness.sut.applyModelLabels([ModelOption(value: "opus", label: "First"), ModelOption(value: "opus", label: "Second")], backend: "claude")

        // then
        #expect(harness.sut.columns.first?.caption == "Claude · First")
    }

    // MARK: - Lifecycle

    @Test func givenAnOldRequestInFlight_whenTheScreenReappearsAndTheNewAnswerComesFirst_thenTheOldAnswerChangesNothing() async {
        // given: a request held open by the controlled catalog.
        let harness = makeSUT()
        let gate = CatalogGate()
        harness.sut.modelLabels.loader = { _ in await gate.ask() }
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { gate.asked == 1 }

        // when: the screen leaves and returns, so a new request starts; the new answer is released first, then the old one.
        harness.sut.didDisappear()
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { gate.asked == 2 }
        gate.answer(1, [ModelOption(value: "opus", label: "New 5.5")])
        await waitUntil { harness.sut.columns.first?.caption == "Claude · New 5.5" }
        gate.answer(0, [ModelOption(value: "opus", label: "Old 5.5")])
        await drain()

        // then: the old answer neither changed a caption nor touched the newer request's bookkeeping.
        #expect(harness.sut.columns.first?.caption == "Claude · New 5.5")
        #expect(harness.sut.modelLabels.labels["claude"] == ["opus": "New 5.5"])
        #expect(harness.sut.modelLabels.requested == ["claude"])
        #expect(harness.sut.modelLabels.requests.isEmpty)
    }

    @Test func givenAnOldRequestInFlight_whenTheScreenReappearsAndTheOldAnswerComesFirst_thenTheNewRequestStaysInFlightAndWins() async {
        // given
        let harness = makeSUT()
        let gate = CatalogGate()
        harness.sut.modelLabels.loader = { _ in await gate.ask() }
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { gate.asked == 1 }
        harness.sut.didDisappear()
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { gate.asked == 2 }

        // when: the stale answer arrives while the newer request is still open.
        gate.answer(0, [ModelOption(value: "opus", label: "Old 5.5")])
        await drain()

        // then: nothing changed and the newer request is still tracked.
        #expect(harness.sut.columns.first?.caption == "Claude · opus")
        #expect(harness.sut.modelLabels.labels["claude"] == nil)
        #expect(harness.sut.modelLabels.requested == ["claude"])
        #expect(harness.sut.modelLabels.requests.count == 1)

        // when
        gate.answer(1, [ModelOption(value: "opus", label: "New 5.5")])

        // then
        await waitUntil { harness.sut.columns.first?.caption == "Claude · New 5.5" }
        #expect(harness.sut.modelLabels.requests.isEmpty)
    }

    /// One gated first build over a single lane. With `label`, the engine's label lands while that build is held open.
    private func gatedBuild(label: Bool) async -> (builds: Int, cancelled: Bool, built: Int, held: String?, final: String?) {
        let gate = BuildGate()
        let harness = makeSUT(buildColumns: { inputs in
            await gate.hold()
            return await ParallelPresentationBuilder.buildColumns(inputs)
        })
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { gate.started && harness.sut.leasedMemberCount == 1 }
        await drain()
        let builtBefore = harness.sut.builtColumnCount
        if label { harness.sut.applyModelLabels([ModelOption(value: "opus", label: "Opus 5.5")], backend: "claude") }
        #expect(harness.sut.builtColumnCount == builtBefore, "the label arrival built nothing")
        let held = harness.sut.columns.first?.caption
        gate.release()
        await waitUntil { harness.sut.builtColumnCount >= 1 && harness.sut.isPresentationSettled }
        return (gate.holds, gate.cancelled, harness.sut.builtColumnCount, held, harness.sut.columns.first?.caption)
    }

    @Test func givenABuildInFlight_whenTheLabelArrives_thenTheBuildIsNotRescheduledOrCancelledAndItsResultKeepsTheNewCaption() async {
        // given / when: the same gated build with and without the label landing while it is held open
        let plain = await gatedBuild(label: false)
        let labelled = await gatedBuild(label: true)

        // then: the label changed no build count, cancellation or commit; only the caption differs (other sources, such as lease acquisition, reschedule the plain run too)
        #expect(plain.held == "Claude · opus" && plain.final == "Claude · opus")
        #expect(labelled.held == "Claude · Opus 5.5", "the caption shows at once, before the build commits")
        #expect(labelled.final == "Claude · Opus 5.5", "the committed column keeps the new caption")
        #expect(labelled.builds == plain.builds)
        #expect(labelled.cancelled == plain.cancelled)
        #expect(labelled.built == plain.built)
    }

    @Test func givenAMemberWhoseSnapshotChangesItsBackend_whenLanesAppear_thenTheSnapshotsBackendIsAsked() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        let listed = task(id: "a", backend: "claude", model: "opus")
        let snapshot = task(id: "a", backend: "codex", model: "opus")
        harness.tasksBox.value["a"] = listed
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.snapshotsSubject.send(["a": snapshot])

        // when
        harness.tasksSubject.send([listed])
        await waitUntil { catalog.calls.count >= 1 }
        await drain()

        // then
        #expect(catalog.calls == ["codex"])
    }

    @Test func givenAnEmptyAnswer_whenTheScreenReappears_thenTheBackendIsAskedAgain() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { catalog.calls == ["claude"] }
        await drain()
        #expect(harness.sut.columns.first?.caption == "Claude · opus")
        harness.tasksSubject.send([running])
        await drain()
        #expect(catalog.calls == ["claude"], "an empty answer is not retried within an appearance")
        harness.sut.didDisappear()

        // when
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])

        // then
        await waitUntil { harness.sut.columns.first?.caption == "Claude · Opus 5.5" }
        #expect(catalog.calls == ["claude", "claude"])
    }

    @Test func givenLoadedLabels_whenTheScreenReappears_thenTheyAreKeptAndTheCatalogIsAskedOnceMore() async {
        // given
        let harness = makeSUT()
        let catalog = harness.catalog
        catalog.answers["claude"] = [ModelOption(value: "opus", label: "Opus 5.5")]
        let running = task(id: "a", model: "opus")
        harness.tasksBox.value["a"] = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.columns.first?.caption == "Claude · Opus 5.5" }
        harness.sut.didDisappear()

        // when
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.columns.count == 1 }

        // then: the first published caption already carries the kept label, and one new request refreshes it.
        #expect(harness.sut.columns.first?.caption == "Claude · Opus 5.5")
        await waitUntil { catalog.calls.count == 2 }
        #expect(catalog.calls == ["claude", "claude"])
    }
}
