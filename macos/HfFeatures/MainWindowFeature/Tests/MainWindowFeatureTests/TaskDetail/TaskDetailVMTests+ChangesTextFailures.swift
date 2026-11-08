import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - Failures, delayed results and the persisted selection

@MainActor
extension TaskDetailVMTests {
    private var readme: TaskChangesSelector { ChangesJSON.selector("README.md") }
    private var readmeHeader: TaskChangesDiffHeader { TaskChangesDiffHeader(path: "README.md", scope: "Committed") }

    // MARK: Text errors

    @Test(arguments: [0, 1])
    func givenTheStoredChangesWereReplaced_whenAPatchReadIsRefused_thenTheSelectionDropsAndTheListingIsReadAgain(which: Int) async throws {
        // given: changes_entry_not_found, then changes_cursor_expired
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .failure(.failed(which == 0 ? ChangesJSON.entryNotFound : ChangesJSON.cursorExpired)))
        let firstGeneration = rig.listing.calls[0].key.generation

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { rig.listing.count == 2 }

        // then: the failure names the dropped row until the replacement listing is applied
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.listing.calls[1].key.generation > firstGeneration)
        await waitUntil { rig.sut.changesDiff == .none }
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesTabCount == 6)
    }

    @Test func givenTheReloadNote_whenReloadChangesIsTapped_thenTheListingIsReadFromTheStart() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .failure(.failed(ChangesJSON.entryNotFound)))
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { rig.listing.count == 2 && rig.sut.changesTabCount == 6 }
        let sut = rig.sut

        // when
        sut.didTapReloadChanges()
        await waitUntil { rig.listing.count == 3 }

        // then
        #expect(rig.listing.calls.map(\.key.generation) == rig.listing.calls.map(\.key.generation).sorted())
    }

    @Test func givenAClientBoundOnAPatchRead_whenItFails_thenTheClientBoundSentenceShowsWithRetryAndTheSelectionStays() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .failure(.clientBound(.requestBudget)))

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffFailureShown(rig.sut) }

        // then
        #expect(rig.sut.changesDiff == .failure(readmeHeader, TaskChangesDiffBuilder.Failure.clientBound.note))
        #expect(TaskChangesDiffBuilder.Failure.clientBound.note.detail == TaskChangesFailure.clientBoundSentence)
        #expect(rig.sut.changesSelection?.selector == readme)
        #expect(rig.listing.count == 1, "a client bound does not reload the listing")
    }

    @Test(arguments: [0, 1])
    func givenAnotherFailure_whenARetryIsTapped_thenThePatchIsReadAgainAndTheDiffShows(which: Int) async throws {
        // given: a transport timeout, an invalid cursor
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let outcomes: [TaskChangesReadFailure.Outcome] = [
            .failed(.timedOut(tool: "harflow-ctl", seconds: 30)), .failed(ChangesJSON.cursorInvalid)
        ]
        rig.patches.answer(0, .failure(outcomes[which]))
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffFailureShown(rig.sut) }
        #expect(rig.sut.changesDiff == .failure(readmeHeader, TaskChangesDiffBuilder.Failure.other.note))

        // when
        rig.sut.didTapRetryChangesDiff()
        await waitUntil { isDiffShown(rig.sut) }

        // then
        #expect(rig.patches.count == 2)
        #expect(rig.listing.count == 1)
    }

    @Test func givenAFailedDiff_whenTheSameRowIsSelectedAgain_thenItIsReadAgain() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .failure(.clientBound(.deadline)))
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffFailureShown(rig.sut) }

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffShown(rig.sut) }

        // then
        #expect(rig.patches.count == 2)
    }

    @Test func givenASupersededPatchRead_whenItAnswers_thenItIsReadOnceMoreAndTheDiffShows() async throws {
        // given: the runtime changed under the first read
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .failure(.superseded))

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffShown(rig.sut) }

        // then
        #expect(rig.patches.count == 2)
        #expect(rig.patches.calls[1].key == rig.patches.calls[0].key)
    }

    @Test func givenTwoSupersededPatchReads_whenTheSecondAnswers_thenItIsShownAsAnOrdinaryFailureWithRetry() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answerFromNowOn(.failure(.superseded))

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffFailureShown(rig.sut) }

        // then
        #expect(rig.patches.count == 2, "repeated once, not looped")
        #expect(rig.sut.changesDiff == .failure(readmeHeader, TaskChangesDiffBuilder.Failure.other.note))
    }

    @Test func givenARetryFailure_whenTheSelectionIsDropped_thenTheStaleRetryNoteClears() async throws {
        // given: the row's read failed with a Retry note, then the listing is replaced by one without the row
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .failure(.clientBound(.deadline)))
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffFailureShown(rig.sut) }
        rig.listing.answerFromNowOn(.snapshot(try ChangesJSON.zeroRows()))

        // when
        rig.sut.changesLifecycle.needsRead = true
        rig.sut.evaluateChangesDemand()
        await waitUntil { rig.sut.changesTabCount == 0 }

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == .none)
    }

    // MARK: Delayed results

    @Test func givenAReadInFlight_whenTheViewDisappears_thenTheLateResultNeverAppliesAndTheSelectionIsKept() async throws {
        // given
        let rig = try await openTextRig()
        let sut = rig.sut
        rig.patches.whileInFlight(0) { sut.didDisappear() }

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { rig.patches.count == 1 }
        await waitUntil(timeout: 0.3) { isDiffShown(rig.sut) }

        // then
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.sut.changesSelection?.selector == readme, "disappearing keeps the selection for the pane store")
        #expect(!rig.patches.calls[0].fence())
        #expect(rig.sut.changesPresentation == .loading)
    }

    @Test func givenAReadInFlight_whenTheTaskGoesMissing_thenTheLateResultNeverApplies() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let sut = rig.sut
        let harness = rig.rig.harness
        rig.patches.whileInFlight(0) {
            harness.detailBox.value = nil
            sut.recompute()
        }

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { rig.patches.count == 1 }
        await waitUntil(timeout: 0.3) { isDiffShown(rig.sut) }

        // then
        #expect(rig.sut.task == nil)
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.sut.changesSelection?.selector == readme)
        #expect(!rig.patches.calls[0].fence())
    }

    @Test func givenAReadInFlight_whenTheListingIsRefreshed_thenTheOldResultIsDroppedAndTheRowIsReadAgainOnTheNewListing() async throws {
        // given: the refresh replaces the listing; the re-read of the row answers with a dropped key, so only the old result could show
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let sut = rig.sut
        rig.patches.answer(0, .text("@@ -1 +1 @@\n+OLD\n"))
        rig.patches.answer(1, .wrongKey("@@ -1 +1 @@\n+NEVER\n"))
        rig.patches.whileInFlight(0) { sut.didTapRetryChanges() }

        // when
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { rig.patches.count == 2 }
        await waitUntil(timeout: 0.3) { isDiffShown(rig.sut) }

        // then
        #expect(rig.listing.count == 2)
        #expect(rig.sut.changesDiff == .loading(readmeHeader))
        #expect(rig.sut.changesSelection?.selector == readme)
        #expect(!rig.patches.calls[0].fence())
    }

    @Test func givenAnIdenticalRefreshedListing_whenItApplies_thenTheShownDiffIsNotReadAgain() async throws {
        // given: a re-read that produces the same row facts leaves the listing, and so the diff, as it is
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffShown(rig.sut) }
        let sut = rig.sut

        // when: a status-neutral epoch that keeps the shown listing (no loading state)
        sut.changesLifecycle.needsRead = true
        sut.evaluateChangesDemand()
        await waitUntil { rig.listing.count == 2 }
        await waitUntil(timeout: 0.3) { rig.patches.count > 1 }

        // then
        #expect(rig.patches.count == 1)
        #expect(isDiffShown(rig.sut))
    }

    @Test func givenAChangedCountOrByteSize_whenTheListingIsRefreshed_thenTheShownDiffIsReadAgain() async throws {
        // given: the same rows and states, but README.md now reports more bytes and one more addition
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectChangesRow(readme)
        await waitUntil { isDiffShown(rig.sut) }
        rig.listing.answerFromNowOn(.snapshot(try ChangesJSON.availableListing(readmeBytes: 43, readmeAdditions: 2)))

        // when
        rig.sut.changesLifecycle.needsRead = true
        rig.sut.evaluateChangesDemand()
        await waitUntil { rig.patches.count == 2 }

        // then
        #expect(rig.listing.count == 2)
        #expect(!rig.patches.calls[0].fence())
        await waitUntil { isDiffShown(rig.sut) }
    }

    // MARK: Persisted selection

    @Test func givenARememberedRowThatIsPresentWithText_whenTheListingLoads_thenItsPatchIsRead() async throws {
        // given
        let rig = try await openTextRig(paneOpen: false)
        defer { rig.sut.didDisappear() }
        let remembered = TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("src/app.py", scope: .workingTree))

        // when
        rig.sut.restoreChangesSelection(remembered)
        #expect(rig.sut.changesSelection == remembered)
        #expect(rig.patches.isEmpty, "nothing is read before the listing confirms the row")
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { isDiffShown(rig.sut) }

        // then
        #expect(rig.patches.calls.map(\.selector) == [remembered.selector])
        #expect(shownDiff(rig.sut)?.header == TaskChangesDiffHeader(path: "src/app.py", scope: "Working tree"))
    }

    @Test func givenARememberedRowThatIsPresentWithoutText_whenTheListingLoads_thenItIsSelectedWithItsLabelAndNothingIsRead() async throws {
        // given
        let rig = try await openTextRig(paneOpen: false)
        defer { rig.sut.didDisappear() }
        let remembered = TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("assets/logo.png"))

        // when
        rig.sut.restoreChangesSelection(remembered)
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesDiff != .none }

        // then
        #expect(rig.sut.changesDiff == .noText(TaskChangesDiffHeader(path: "assets/logo.png", scope: "Committed"), label: "Binary"))
        #expect(rig.sut.changesSelection == remembered)
        #expect(rig.patches.isEmpty)
    }

    @Test func givenARememberedRowThatIsAbsent_whenTheListingLoads_thenTheSelectionIsDroppedSilently() async throws {
        // given
        let rig = try await openTextRig(paneOpen: false)
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.restoreChangesSelection(TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("gone.txt")))
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesTabCount == 6 }

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.patches.isEmpty)
    }

    @Test func givenARememberedRowOfAnotherMember_whenRestored_thenItIsDropped() async throws {
        // given: the listing for t1 is already applied
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.restoreChangesSelection(TaskChangesSelection(taskID: "someone-else", selector: readme))

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.patches.isEmpty)
    }

    @Test func givenARememberedRowAndAListingThatIsANote_whenItLoads_thenTheSelectionStaysAndNothingIsRead() async throws {
        // given: the stored changes are still settling, so the note neither confirms nor refutes the row
        let rig = try await openTextRig(paneOpen: false, reply: try settlingReply)
        defer { rig.sut.didDisappear() }
        let remembered = TaskChangesSelection(taskID: "t1", selector: readme)

        // when
        rig.sut.restoreChangesSelection(remembered)
        rig.sut.setChangesPaneOpen(true)
        await waitUntil { rig.sut.changesCaptureSettling }

        // then
        #expect(rig.sut.changesSelection == remembered)
        #expect(rig.patches.isEmpty)
    }

    @Test func givenASelectionAlreadyMade_whenAnotherIsRestored_thenTheLiveSelectionWins() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectChangesRow(readme)

        // when
        rig.sut.restoreChangesSelection(TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("src/app.py")))

        // then
        #expect(rig.sut.changesSelection?.selector == readme)
    }
}
