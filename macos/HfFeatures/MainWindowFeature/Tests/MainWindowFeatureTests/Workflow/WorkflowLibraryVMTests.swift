import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Observation
import Testing

// MARK: - WorkflowLibraryVMTests

@MainActor @Suite struct WorkflowLibraryVMTests {
    @Test func givenUnmountedLibrary_whenMountedTwiceThenRemoved_thenOwnsOneReadAndReleasesWait() async throws {
        // given
        let h = LibraryTestHarness()
        #expect(h.useCase.contexts.isEmpty)
        // when
        h.vm.didAppear()
        h.vm.didAppear()
        await waitUntil { h.vm.presentation.phase == .loaded }
        // then
        #expect(h.useCase.contexts.count == 1)
        h.vm.didDisappear()
        h.scheduler.fireOneShot(interval: 2)
        #expect(h.vm.presentation.rows.isEmpty)
        #expect(h.useCase.contexts.count == 1)
    }

    @Test func givenCatalog_whenRowsArePrepared_thenMissingMetadataIsOmittedAndRealNodeCountIsRetained() async throws {
        // given
        let h = LibraryTestHarness()
        h.useCase.response = ["workflows": .array([
            .object(["name": .string("unknown-metadata")]),
            .object(["name": .string("actual"), "definition": .object([
                "description": .string("Reported description"), "nodes": .array([.object([:])])
            ])])
        ])]
        // when
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.vm.presentation.rows.count == 2 }
        // then
        #expect(h.vm.presentation.rows[0].nodeCount == nil)
        #expect(h.vm.presentation.rows[0].description == nil)
        #expect(h.vm.presentation.rows[1].nodeCount == 1)
        #expect(h.vm.presentation.rows[1].description == "Reported description")
    }

    @Test func givenCurrentRow_whenEditRunAndNewAreRequested_thenRoutesExactNamesWithoutReadingAgain() async throws {
        // given
        let h = LibraryTestHarness()
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { !h.vm.presentation.rows.isEmpty }
        let row = try #require(h.vm.presentation.rows.first)
        // when
        h.vm.edit(row); h.vm.run(row)
        h.vm.create(generate: false); h.vm.create(generate: true)
        // then
        #expect(h.routing.edits == ["implement-review"])
        #expect(h.routing.runs == ["implement-review"])
        #expect(h.routing.creations == [false, true])
        #expect(h.useCase.contexts.count == 1)
    }

    @Test func givenCopiedNameAcrossRuntimeABA_whenOldCallbacksArrive_thenTheyNeverRoute() async throws {
        // given
        let h = LibraryTestHarness()
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { !h.vm.presentation.rows.isEmpty }
        let old = try #require(h.vm.presentation.rows.first)
        let runtimeA = h.useCase.selected.runtime
        // when — B, then the same A binding under a new observation epoch.
        h.useCase.selected = LibraryTestUseCase.context("B")
        h.vm.edit(old)
        h.useCase.selected = .init(runtime: runtimeA, epoch: UUID())
        h.vm.run(old)
        await waitUntil { h.vm.presentation.rows.first?.context == h.useCase.selected }
        h.vm.edit(old); h.vm.run(old)
        // then
        #expect(h.routing.edits.isEmpty)
        #expect(h.routing.runs.isEmpty)
        let fresh = try #require(h.vm.presentation.rows.first)
        h.vm.run(fresh)
        #expect(h.routing.runs == ["implement-review"])
    }

    @Test func givenSuspendedRead_whenRuntimeChangesOrMountEnds_thenLateRowsCannotApply() async throws {
        // given
        let h = LibraryTestHarness()
        h.useCase.suspended = true
        h.vm.didAppear()
        await waitUntil { h.useCase.pending != nil }
        // when
        h.useCase.selected = LibraryTestUseCase.context("B")
        h.vm.didDisappear()
        h.useCase.finish()
        // then
        #expect(h.vm.presentation.rows.isEmpty)
        #expect(h.routing.edits.isEmpty)
    }

    @Test func givenSuccessfulRows_whenRefreshFails_thenRetainsRowsAndFailureDetails() async throws {
        // given
        let h = LibraryTestHarness()
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { !h.vm.presentation.rows.isEmpty && h.scheduler.oneShotCount(interval: 2) == 1 }
        let rows = h.vm.presentation.rows
        h.useCase.failure = ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "Fixture read failure")
        // when
        h.scheduler.fireOneShot(interval: 2)
        await waitUntil { h.vm.presentation.error != nil }
        // then
        #expect(h.vm.presentation.phase == .loaded)
        #expect(h.vm.presentation.rows == rows)
    }

    @Test func givenFailedOrPreparingOrEmptyCatalog_whenReadCompletes_thenOnlySuccessfulEmptyMeansEmpty() async throws {
        // given
        let h = LibraryTestHarness()
        h.useCase.response = [:]
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.vm.presentation.phase == .failed }
        // when
        h.useCase.response = ["workflows": .array([])]
        h.vm.retry()
        await waitUntil { h.vm.presentation.phase == .empty }
        // then
        #expect(h.vm.presentation.error == nil)
        #expect(h.vm.presentation.rows.isEmpty)
    }

    @Test func givenUnchangedPoll_whenSameRowsReturn_thenPresentationDoesNotPublishAgain() async throws {
        // given
        let h = LibraryTestHarness()
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.vm.presentation.phase == .loaded && h.scheduler.oneShotCount(interval: 2) == 1 }
        let changes = PollCounter()
        withObservationTracking { _ = h.vm.presentation } onChange: { changes.increment() }
        // when
        h.scheduler.fireOneShot(interval: 2)
        await waitUntil { h.useCase.contexts.count == 2 && h.scheduler.oneShotCount(interval: 2) == 1 }
        // then
        #expect(changes.value == 0)
    }

    @Test func givenRowsFromPreviousMount_whenViewReappears_thenStaleCallbackCannotRoute() async throws {
        // given
        let h = LibraryTestHarness()
        h.vm.didAppear()
        await waitUntil { !h.vm.presentation.rows.isEmpty }
        let old = try #require(h.vm.presentation.rows.first)
        // when
        h.vm.didDisappear()
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { !h.vm.presentation.rows.isEmpty }
        h.vm.run(old)
        // then
        #expect(h.routing.runs.isEmpty)
    }

    @Test func givenHiddenLibrary_whenVisibilityReturns_thenReadsOnceWithoutPerRowTimers() async throws {
        // given
        let h = LibraryTestHarness()
        h.visibility.setMainWindowVisible(false)
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.scheduler.oneShotCount(interval: 2) == 1 }
        #expect(h.useCase.contexts.isEmpty)
        // when
        h.visibility.setMainWindowVisible(true)
        await waitUntil { h.vm.presentation.phase == .loaded }
        // then
        #expect(h.useCase.contexts.count == 1)
        #expect(h.scheduler.repeats.isEmpty)
    }

    @Test func givenPreparingCatalog_whenReadCompletes_thenKeepsLoadingInsteadOfShowingEmpty() async throws {
        // given
        let h = LibraryTestHarness()
        h.useCase.response = ["bootstrap_pending": .bool(true)]
        // when
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.scheduler.oneShotCount(interval: 2) == 1 }
        // then
        #expect(h.vm.presentation.phase == .loading)
        #expect(h.vm.presentation.error == nil)
    }

    @Test func givenSuspendedReadFromRuntimeA_whenBThenSameRuntimeAReturns_thenLateCompletionIsRejected() async throws {
        // given
        let h = LibraryTestHarness()
        let runtimeA = h.useCase.selected.runtime
        h.useCase.suspended = true
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.useCase.pending != nil }
        // when
        h.useCase.selected = LibraryTestUseCase.context("B")
        h.useCase.selected = .init(runtime: runtimeA, epoch: UUID())
        h.useCase.suspended = false
        h.useCase.finish()
        await waitUntil { h.scheduler.oneShotCount(interval: 2) == 1 }
        // then
        #expect(h.vm.presentation.rows.isEmpty)
        h.scheduler.fireOneShot(interval: 2)
        await waitUntil { h.vm.presentation.phase == .loaded }
        #expect(h.vm.presentation.rows.first?.context == h.useCase.selected)
    }

    @Test(arguments: [true, false])
    func givenSuccessfulRows_whenManualRetryFailsOrPrepares_thenRetainedActionsStillRoute(failed: Bool) async throws {
        // given
        let h = LibraryTestHarness()
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.vm.presentation.phase == .loaded && h.scheduler.oneShotCount(interval: 2) == 1 }
        let row = try #require(h.vm.presentation.rows.first)
        if failed {
            h.useCase.failure = ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "Fixture failure")
        } else {
            h.useCase.response = ["bootstrap_pending": .bool(true)]
        }
        // when
        h.vm.retry()
        await waitUntil { h.useCase.contexts.count == 2 && h.scheduler.oneShotCount(interval: 2) == 2 }
        h.vm.edit(row); h.vm.run(row)
        // then
        #expect(h.routing.edits == [row.name])
        #expect(h.routing.runs == [row.name])
    }

    @Test func givenSuccessfulRows_whenVisibilityRefreshFails_thenRetainedActionsStillRoute() async throws {
        // given
        let h = LibraryTestHarness()
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.vm.presentation.phase == .loaded && h.scheduler.oneShotCount(interval: 2) == 1 }
        let row = try #require(h.vm.presentation.rows.first)
        h.useCase.failure = ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "Fixture failure")
        // when
        h.visibility.setMainWindowVisible(false)
        h.visibility.setMainWindowVisible(true)
        await waitUntil { h.vm.presentation.error != nil }
        h.vm.edit(row); h.vm.run(row)
        // then
        #expect(h.routing.edits == [row.name])
        #expect(h.routing.runs == [row.name])
    }

    @Test func givenInitialFailure_whenRetryIsPreparing_thenFailureRemainsAccessibleUntilReady() async throws {
        // given
        let h = LibraryTestHarness()
        h.useCase.response = [:]
        h.vm.didAppear()
        defer { h.vm.didDisappear() }
        await waitUntil { h.vm.presentation.phase == .failed && h.scheduler.oneShotCount(interval: 2) == 1 }
        let failure = h.vm.presentation.error
        #expect(failure == "Saved workflows could not be read completely. Refresh workflows to try again.")
        // when
        h.useCase.response = ["bootstrap_pending": .bool(true)]
        h.vm.retry()
        await waitUntil { h.useCase.contexts.count == 2 && h.scheduler.oneShotCount(interval: 2) == 2 }
        // then
        #expect(h.vm.presentation.phase == .failed)
        #expect(h.vm.presentation.error == failure)
    }

    @Test func givenGenerationIntent_whenNavigationChanges_thenIntentNeverLeaksToAnotherDraft() {
        // given
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        // when
        coordinator.newLibraryWorkflow(generate: true)
        guard case let .newWorkflow(identity) = coordinator.selection else { Issue.record("Missing new-workflow destination"); return }
        // then
        #expect(coordinator.workflowGenerationIntent == identity)
        #expect(coordinator.workflowEditorMountIdentity(name: nil) == identity.uuidString)
        #expect(coordinator.workflowEditorMountIdentity(name: "saved") == "saved")
        coordinator.selection = .workflowLibrary
        #expect(coordinator.workflowGenerationIntent == nil)
        coordinator.newLibraryWorkflow(generate: false)
        #expect(coordinator.workflowEditorMountIdentity(name: nil) != identity.uuidString)
        #expect(coordinator.workflowGenerationIntent == nil)
    }
}
