import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - The turn picker

@MainActor
extension TaskDetailVMTests {

    struct TurnRig {
        let harness: ConversationSUT
        let scheduler: CapturingScheduler
        let listing: ChangesReadScript
        let patches: ChangesPatchScript
        let members: [TaskInfo]
        var sut: TaskDetailVM { harness.sut }
    }

    /// A standalone conversation of the given members, oldest first, opened and listed, with the pane open and the current turn read.
    func openTurnRig(ids: [String] = ["a", "b", "c"], stubbed: [String]? = nil) async throws -> TurnRig {
        let scheduler = CapturingScheduler()
        let members = ids.enumerated().map { index, id in
            conversationTask(id, status: "completed", parentTaskID: index == 0 ? nil : ids[index - 1], minute: index)
        }
        let all = (stubbed ?? ids).enumerated().map { index, id in
            conversationTask(id, status: "completed", parentTaskID: index == 0 ? nil : (stubbed ?? ids)[index - 1], minute: index)
        }
        let harness = makeConversationSUT(openedAs: ids[0], initialMembers: members, stubbedMembers: all, chrome: .standalone, scheduler: scheduler)
        let listing = ChangesReadScript(.snapshot(try ChangesJSON.availableListing()))
        let patches = ChangesPatchScript()
        given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, fence in listing.serve(key, fence) }
        given(harness.useCase).readChangesPatch(key: .any, selector: .any, operationIsCurrent: .any).willProduce { key, selector, fence in
            patches.serve(key, selector, fence)
        }
        harness.sut.didAppear()
        harness.tasksSubject.send(members)
        await waitUntil { harness.sut.task != nil }
        harness.sut.setChangesPaneOpen(true)
        await waitUntil { harness.sut.changesTabCount == 6 }
        return TurnRig(harness: harness, scheduler: scheduler, listing: listing, patches: patches, members: all)
    }

    private func publish(_ rig: TurnRig, members: [TaskInfo]) {
        rig.harness.membersBox.value = members
        rig.harness.tasksSubject.send(members)
    }

    @Test func givenASingleMemberConversation_whenShown_thenThereIsNoPicker() async throws {
        // given / when
        let rig = try await openTurnRig(ids: ["a"])
        defer { rig.sut.didDisappear() }
        // then
        #expect(rig.sut.changesTurns == nil)
        #expect(rig.sut.changesReadMemberID == "a")
    }

    @Test func givenThreeTurns_whenShown_thenThePickerListsThemNewestFirstWithTheCurrentTurnSelectedAndRead() async throws {
        // given / when
        let rig = try await openTurnRig()
        defer { rig.sut.didDisappear() }

        // then
        let picker = try #require(rig.sut.changesTurns)
        #expect(picker.options.map(\.id) == ["c", "b", "a"])
        #expect(picker.options.map(\.title) == ["Turn 3 of 3 \u{B7} current", "Turn 2 of 3", "Turn 1 of 3"])
        #expect(picker.selectedID == "c")
        #expect(rig.sut.changesReadMemberID == "c")
        #expect(rig.listing.calls.map(\.key.taskID) == ["c"])
    }

    @Test func givenAnEarlierTurn_whenSelected_thenThatMembersListingIsReadInANewGenerationAndTheTabCountFollows() async throws {
        // given
        let rig = try await openTurnRig()
        defer { rig.sut.didDisappear() }
        let before = rig.listing.calls[0].key.generation
        rig.listing.answer(1, .snapshot(try ChangesJSON.zeroRows()))

        // when
        rig.sut.didSelectChangesTurn("a")
        #expect(rig.sut.changesPresentation == .loading)
        #expect(rig.sut.changesTabCount == nil)
        await waitUntil { rig.sut.changesTabCount == 0 }

        // then
        #expect(rig.listing.calls.map(\.key.taskID) == ["c", "a"])
        #expect(rig.listing.calls[1].key.generation > before)
        #expect(rig.sut.changesReadMemberID == "a")
        #expect(rig.sut.changesTurns?.selectedID == "a")
        #expect(rig.sut.changesTurns?.shortID == "a")
    }

    @Test func givenTheSelectedTurn_whenItIsSelectedAgainOrAnUnknownOneIs_thenNothingIsRead() async throws {
        // given
        let rig = try await openTurnRig()
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.didSelectChangesTurn("c")
        rig.sut.didSelectChangesTurn("not-a-member")
        await waitUntil(timeout: 0.3) { rig.listing.count > 1 }

        // then
        #expect(rig.listing.count == 1)
        #expect(rig.sut.changesReadMemberID == "c")
    }

    @Test func givenAnEarlierTurnShown_whenTheCurrentTurnIsPickedAgain_thenTheCurrentMemberIsRead() async throws {
        // given
        let rig = try await openTurnRig()
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectChangesTurn("a")
        await waitUntil { rig.listing.count == 2 && rig.sut.changesTabCount == 6 }

        // when
        rig.sut.didSelectChangesTurn("c")
        await waitUntil { rig.listing.count == 3 }

        // then
        #expect(rig.listing.calls.map(\.key.taskID) == ["c", "a", "c"])
        #expect(rig.sut.changesLifecycle.selectedTurn == nil)
    }

    @Test func givenAnEarlierTurnShown_whenANewMemberAppears_thenThePickerResetsToTheNewCurrentTurn() async throws {
        // given
        let rig = try await openTurnRig(stubbed: ["a", "b", "c", "d"])
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectChangesTurn("a")
        await waitUntil { rig.listing.count == 2 && rig.sut.changesTabCount == 6 }

        // when
        publish(rig, members: rig.members)
        await waitUntil { rig.listing.count == 3 }

        // then
        #expect(rig.listing.calls.last?.key.taskID == "d")
        #expect(rig.sut.changesReadMemberID == "d")
        #expect(rig.sut.changesTurns?.selectedID == "d")
        #expect(rig.sut.changesTurns?.options.count == 4)
    }

    @Test func givenAnEarlierTurnShown_whenThatMemberIsPruned_thenThePickerResetsToTheCurrentTurn() async throws {
        // given
        let rig = try await openTurnRig()
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectChangesTurn("a")
        await waitUntil { rig.listing.count == 2 && rig.sut.changesTabCount == 6 }

        // when: retention prunes the oldest turn
        publish(rig, members: Array(rig.members.dropFirst()))
        await waitUntil { rig.listing.count == 3 }

        // then
        #expect(rig.listing.calls.last?.key.taskID == "c")
        #expect(rig.sut.changesTurns?.options.map(\.id) == ["c", "b"])
        #expect(rig.sut.changesTurns?.selectedID == "c")
    }

    @Test func givenARowSelectedInTheCurrentTurn_whenAnotherTurnIsPicked_thenTheSelectionAndItsInFlightPatchAreDroppedDespiteIdenticalSelectors() async throws {
        // given: both turns list the same paths, so the selector alone cannot tell them apart
        let rig = try await openTurnRig()
        defer { rig.sut.didDisappear() }
        let sut = rig.sut
        let address = ChangesJSON.selector("README.md")
        rig.patches.answer(0, .text("@@ -1 +1 @@\n+FROM-C\n"))
        rig.patches.whileInFlight(0) { sut.didSelectChangesTurn("a") }

        // when
        rig.sut.didSelectChangesRow(address)
        await waitUntil { rig.patches.count == 1 && rig.listing.count == 2 }
        await waitUntil { rig.sut.changesTabCount == 6 }
        await waitUntil(timeout: 0.3) { isDiffShown(rig.sut) }

        // then: the late result of turn c never shows in turn a
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.patches.calls[0].key.taskID == "c")
        #expect(!rig.patches.calls[0].fence())

        // when: the same row is chosen in turn a
        rig.sut.didSelectChangesRow(address)
        await waitUntil { isDiffShown(rig.sut) }

        // then: it is read for turn a
        #expect(rig.patches.calls[1].key.taskID == "a")
        #expect(rig.sut.changesSelection == TaskChangesSelection(taskID: "a", selector: address))
        #expect(shownDiff(rig.sut)?.text.attributed.string.contains("FROM-C") == false)
    }
}
