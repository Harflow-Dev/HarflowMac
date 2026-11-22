import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - Reconciliation exits

/// Every exit of `reconcileChangesSelection` that drops the diff, pinned by what it does to the selection, to a diff that is
/// a reload failure versus a retryable failure, and to the patch generation.
@MainActor
extension TaskDetailVMTests {
    private var reconcileHeader: TaskChangesDiffHeader { TaskChangesDiffHeader(path: "README.md", scope: "Committed") }
    private var reloadFailure: TaskChangesDiffPresentation { .failure(reconcileHeader, TaskChangesDiffBuilder.Failure.reload.note) }
    private var retryFailure: TaskChangesDiffPresentation { .failure(reconcileHeader, TaskChangesDiffBuilder.Failure.other.note) }

    @Test(arguments: [true, false])
    func givenNoSelection_whenReconciled_thenOnlyAReloadFailureSurvivesAndThePatchIsCancelled(reload: Bool) async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.sut.changesSelection = nil
        rig.sut.changesDiff = reload ? reloadFailure : retryFailure
        let generation = rig.sut.changesLifecycle.patchGeneration

        // when
        rig.sut.reconcileChangesSelection()

        // then
        #expect(rig.sut.changesDiff == (reload ? reloadFailure : .none))
        #expect(rig.sut.changesLifecycle.patchGeneration > generation)
        #expect(rig.sut.changesPatchTask == nil)
        #expect(rig.patches.isEmpty)
    }

    @Test(arguments: [true, false])
    func givenSelectionOfAnotherMember_whenReconciled_thenItIsClearedAndOnlyAReloadFailureSurvives(reload: Bool) async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.sut.changesSelection = TaskChangesSelection(taskID: "someone-else", selector: ChangesJSON.selector("README.md"))
        rig.sut.changesDiff = reload ? reloadFailure : retryFailure
        let generation = rig.sut.changesLifecycle.patchGeneration

        // when
        rig.sut.reconcileChangesSelection()

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == (reload ? reloadFailure : .none))
        #expect(rig.sut.changesLifecycle.patchGeneration > generation)
        #expect(rig.patches.isEmpty)
    }

    @Test(arguments: [true, false])
    func givenSelectionAndANoteListing_whenReconciled_thenTheSelectionStaysAndEvenAReloadFailureIsCleared(reload: Bool) async throws {
        // given: the stored changes are still settling, so the applied result is not a listing. This pins today's behaviour.
        let rig = try await openTextRig(reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.changesCaptureSettling }
        let selection = TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("README.md"))
        rig.sut.changesSelection = selection
        rig.sut.changesDiff = reload ? reloadFailure : retryFailure
        let generation = rig.sut.changesLifecycle.patchGeneration

        // when
        rig.sut.reconcileChangesSelection()

        // then
        #expect(rig.sut.changesSelection == selection)
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.sut.changesLifecycle.patchGeneration > generation)
        #expect(rig.sut.changesPatchTask == nil)
        #expect(rig.patches.isEmpty)
    }

    @Test(arguments: [true, false])
    func givenSelectionOfAnAbsentRow_whenReconciled_thenItIsClearedAndOnlyAReloadFailureSurvives(reload: Bool) async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.sut.changesSelection = TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("gone.txt"))
        rig.sut.changesDiff = reload ? reloadFailure : retryFailure
        let generation = rig.sut.changesLifecycle.patchGeneration

        // when
        rig.sut.reconcileChangesSelection()

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == (reload ? reloadFailure : .none))
        #expect(rig.sut.changesLifecycle.patchGeneration > generation)
        #expect(rig.patches.isEmpty)
    }

    @Test func givenSelectionOfARowWithoutText_whenReconciled_thenItIsClearedAndNothingIsRead() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.sut.changesSelection = TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("assets/logo.png"))
        rig.sut.changesDiff = retryFailure

        // when
        rig.sut.reconcileChangesSelection()

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.patches.isEmpty)
    }
}
