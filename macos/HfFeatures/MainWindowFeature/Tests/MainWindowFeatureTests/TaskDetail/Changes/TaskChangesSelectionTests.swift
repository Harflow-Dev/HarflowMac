import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskChangesSelectionTests

/// The selection value, the row facts and the turn picker.
struct TaskChangesSelectionTests {

    @Test func givenTwoSelectionsOfTheSameAddress_whenCompared_thenTheMemberTaskDecidesEquality() {
        // given
        let address = ChangesJSON.selector("a.txt")
        // when / then
        #expect(TaskChangesSelection(taskID: "a", selector: address) == TaskChangesSelection(taskID: "a", selector: address))
        #expect(TaskChangesSelection(taskID: "a", selector: address) != TaskChangesSelection(taskID: "b", selector: address))
        let working = ChangesJSON.selector("a.txt", scope: .workingTree)
        #expect(TaskChangesSelection(taskID: "a", selector: address) != TaskChangesSelection(taskID: "a", selector: working))
    }

    // MARK: Turn picker

    @Test(arguments: [0, 1])
    func givenFewerThanTwoMembers_whenThePickerIsMade_thenThereIsNone(count: Int) {
        // given
        let ids = (0 ..< count).map { "member-\($0)" }
        // when / then
        #expect(TaskChangesTurnPicker.make(memberIDs: ids, selectedID: ids.first ?? "x") == nil)
    }

    @Test func givenThreeMembers_whenThePickerIsMade_thenOptionsRunNewestFirstWithTheCurrentMarked() throws {
        // given
        let ids = ["aaaaaaaa-0001", "bbbbbbbb-0002", "cccccccc-0003"]

        // when
        let picker = try #require(TaskChangesTurnPicker.make(memberIDs: ids, selectedID: "cccccccc-0003"))

        // then
        #expect(picker.options.map(\.id) == ["cccccccc-0003", "bbbbbbbb-0002", "aaaaaaaa-0001"])
        #expect(picker.options.map(\.title) == ["Turn 3 of 3 \u{B7} current", "Turn 2 of 3", "Turn 1 of 3"])
        #expect(picker.selectedID == "cccccccc-0003")
        #expect(picker.shortID == "cccccccc")
    }

    @Test func givenAnEarlierTurnSelected_whenThePickerIsMade_thenTheShortIDIsThatTasksFirstEightCharacters() throws {
        // given / when
        let picker = try #require(TaskChangesTurnPicker.make(memberIDs: ["abcdefghijkl", "mnopqrstuvwx"], selectedID: "abcdefghijkl"))
        // then
        #expect(picker.shortID == "abcdefgh")
        #expect(picker.options.last?.title == "Turn 1 of 2")
    }

    @Test func givenAShortTaskID_whenThePickerIsMade_thenTheShortIDIsTheWholeID() throws {
        // given / when
        let picker = try #require(TaskChangesTurnPicker.make(memberIDs: ["a", "b"], selectedID: "a"))
        // then
        #expect(picker.shortID == "a")
    }

    @Test func givenThePickerCaption_whenRead_thenTurnsAreNotAddedTogether() {
        // given / when / then
        #expect(TaskChangesTurnPicker.caption == "Each turn is its own task with its own capture. Turns are not added together.")
    }
}
