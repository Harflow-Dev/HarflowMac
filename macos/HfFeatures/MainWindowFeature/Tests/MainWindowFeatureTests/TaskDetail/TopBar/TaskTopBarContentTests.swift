//
//  TaskTopBarContentTests.swift
//  MainWindowFeatureTests
//

import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskTopBarContentTests

/// The content a standalone task publishes: its meta parts and visibility rule, and the chip copy.
@MainActor
@Suite struct TaskTopBarContentTests {

    private func content(meta: [String] = ["claude", "repo"], pending: Bool = false, paneOpen: Bool = false,
                         continuity: Bool = false, notices: Int = 0, access: String? = "Read-only") -> TaskTopBarContent {
        TaskTopBarContent(
            title: "Title", badge: TaskBadgeModel.make(evidence: .init(status: .running, takenOver: false, snapshotStatus: nil,
                                                                      exitCode: nil, logState: nil), startedAt: nil),
            metaParts: meta, isBusy: false, isPending: pending, paneOpen: paneOpen, showsContinuity: continuity,
            noticeCount: notices, accessText: access, startedAt: nil
        )
    }

    // MARK: - Meta text

    @Test func givenMetaParts_whenJoined_thenTheyAreSeparatedByMiddleDots() {
        // given / when
        let text = content(meta: ["claude · opus", "repo", "3 turns"]).metaText

        // then
        #expect(text == "claude · opus · repo · 3 turns")
    }

    @Test func givenNoMetaParts_whenJoined_thenTheTextIsEmpty() {
        // given / when / then
        #expect(content(meta: []).metaText.isEmpty)
    }

    // MARK: - Visibility rule

    @Test func givenAWideIdleTask_whenMetaVisibilityIsAsked_thenMetaShows() {
        // given / when / then
        #expect(content().showsMeta(isNarrow: false))
    }

    @Test func givenNarrow_whenMetaVisibilityIsAsked_thenMetaIsHidden() {
        // given / when / then
        #expect(!content().showsMeta(isNarrow: true))
    }

    @Test func givenAPendingTask_whenMetaVisibilityIsAsked_thenMetaIsHidden() {
        // given / when / then
        #expect(!content(pending: true).showsMeta(isNarrow: false))
    }

    @Test func givenNoMetaParts_whenMetaVisibilityIsAsked_thenMetaIsHidden() {
        // given / when / then
        #expect(!content(meta: []).showsMeta(isNarrow: false))
    }

    @Test(arguments: [(true, 0), (false, 2)])
    func givenAnOpenPaneWithASupervisionChip_whenMetaVisibilityIsAsked_thenMetaIsHidden(continuity: Bool, notices: Int) {
        // given
        let content = content(paneOpen: true, continuity: continuity, notices: notices)

        // when
        let shows = content.showsMeta(isNarrow: false)

        // then
        #expect(content.hasSupervisionChip)
        #expect(!shows)
    }

    @Test(arguments: [(true, 0), (false, 2), (true, 1)])
    func givenAClosedPaneWithASupervisionChip_whenMetaVisibilityIsAsked_thenMetaShows(continuity: Bool, notices: Int) {
        // given
        let content = content(paneOpen: false, continuity: continuity, notices: notices)

        // when
        let shows = content.showsMeta(isNarrow: false)

        // then
        #expect(shows)
    }

    @Test func givenAnOpenPaneWithOnlyTheAccessChip_whenMetaVisibilityIsAsked_thenMetaShows() {
        // given
        let content = content(paneOpen: true, access: "Full access")

        // when
        let shows = content.showsMeta(isNarrow: false)

        // then the access chip is not a supervision chip
        #expect(!content.hasSupervisionChip)
        #expect(shows)
    }

    @Test func givenAnOpenPaneWithoutChips_whenMetaVisibilityIsAsked_thenMetaShows() {
        // given / when / then
        #expect(content(paneOpen: true, access: nil).showsMeta(isNarrow: false))
    }

    // MARK: - Chip inputs

    @Test(arguments: [true, false])
    func givenContent_whenChipsAreDerived_thenTheyCarryTheFlagsAndTheNarrowInput(narrow: Bool) {
        // given
        let content = content(continuity: true, notices: 2, access: "Can publish")

        // when
        let chips = content.chips(isNarrow: narrow)

        // then
        #expect(chips == TaskTopBarChips(showsContinuity: true, noticeCount: 2, accessText: "Can publish", isNarrow: narrow))
    }

    // MARK: - Chip copy

    @Test(arguments: [(1, "1 notice", "Show 1 notice"), (2, "2 notices", "Show 2 notices"), (12, "12 notices", "Show 12 notices")])
    func givenAWideBar_whenNoticesAreCounted_thenTheCopyIsSingularOrPlural(count: Int, text: String, label: String) {
        // given
        let chips = TaskTopBarChips(showsContinuity: false, noticeCount: count, accessText: nil, isNarrow: false)

        // when / then
        #expect(chips.noticesText == text)
        #expect(chips.noticesLabel == label)
    }

    @Test(arguments: [(1, "1", "Show 1 notice"), (2, "2", "Show 2 notices"), (12, "12", "Show 12 notices")])
    func givenANarrowBar_whenNoticesAreCounted_thenTheTextIsTheCountAndTheLabelStaysSpelledOut(count: Int, text: String, label: String) {
        // given
        let chips = TaskTopBarChips(showsContinuity: false, noticeCount: count, accessText: nil, isNarrow: true)

        // when / then
        #expect(chips.noticesText == text)
        #expect(chips.noticesLabel == label)
    }

    @Test func givenTheContinuityChip_whenRead_thenTheCopyIsTheDesignText() {
        // given / when / then
        #expect(TaskTopBarChips.continuityText == "Observation resumed")
        #expect(TaskTopBarChips.continuityLabel == "Observation resumed after a restart. Show details.")
    }

    @Test(arguments: [(false, "Read-only"), (true, "Read-only"), (false, "novel_value")])
    func givenAnAccessChip_whenLabelled_thenTheLabelNamesTheAccessAndTheAction(narrow: Bool, access: String) {
        // given
        let chips = TaskTopBarChips(showsContinuity: false, noticeCount: 0, accessText: access, isNarrow: narrow)

        // when / then the accessible label does not depend on the narrow state
        #expect(chips.accessLabel == "\(access). Show what was enforced.")
    }

    // MARK: - Building from a task

    /// The content the VM builds for a listing row and an optional snapshot.
    private func built(listing: TaskInfo, snapshot: TaskInfo? = nil) async -> TaskTopBarContent? {
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)
        harness.detailBox.value = listing
        harness.snapshotBox.value = snapshot
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([listing])
        await waitUntil { harness.sut.inspectorModel != nil }
        return harness.sut.topBarContent
    }

    private func task(_ edit: (inout [String: JSONValue]) -> Void = { _ in }) -> TaskInfo {
        var raw = TaskDetailVMTests().task(status: "running").raw
        edit(&raw)
        return TaskInfo(.object(raw))!
    }

    @Test func givenNoTask_whenContentIsBuilt_thenThereIsNone() {
        // given
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)

        // when / then
        #expect(harness.sut.topBarContent == nil)
    }

    @Test func givenARunningTask_whenContentIsBuilt_thenItCarriesTitleBadgeMetaAndAccess() async {
        // given
        let listing = task { $0["started_at"] = .string("2026-10-28T09:00:00Z") }

        // when
        let content = await built(listing: listing)

        // then
        #expect(content?.title == "Task abc12345")
        #expect(content?.badge.label == "Running")
        #expect(content?.metaParts == ["claude", "repo"])
        #expect(content?.accessText == "Read-only")
        #expect(content?.isPending == false)
        #expect(content?.paneOpen == false)
        #expect(content?.startedAt == listing.startedAt)
        #expect(content?.startedAt != nil)
    }

    @Test func givenASnapshotNamingAModel_whenContentIsBuilt_thenMetaLeadsWithBackendAndModel() async {
        // given
        let snapshot = task { $0["model"] = .string("opus") }

        // when
        let content = await built(listing: task(), snapshot: snapshot)

        // then
        #expect(content?.metaParts == ["claude · opus", "repo"])
    }

    @Test func givenNoRepository_whenContentIsBuilt_thenMetaOmitsIt() async {
        // given
        let listing = task { $0["repo_path"] = .string("") }

        // when
        let content = await built(listing: listing)

        // then
        #expect(content?.metaParts == ["claude"])
    }

    @Test func givenNoFreedom_whenContentIsBuilt_thenThereIsNoAccessChip() async {
        // given
        let listing = task { $0["freedom"] = nil }

        // when
        let content = await built(listing: listing)

        // then
        #expect(content?.accessText == nil)
    }

    @Test(arguments: ["pending", "queued"])
    func givenAPendingTask_whenContentIsBuilt_thenItIsPendingWithoutAnAccessChip(raw: String) async {
        // given
        let listing = task { $0["status"] = .string(raw) }

        // when
        let content = await built(listing: listing)

        // then
        #expect(content?.isPending == true)
        #expect(content?.accessText == nil)
        #expect(content?.showsMeta(isNarrow: false) == false)
    }

    @Test func givenAnUnrecognisedFreedom_whenContentIsBuilt_thenTheRawValueIsTheAccessText() async {
        // given
        let listing = task { $0["freedom"] = .string("novel_freedom") }

        // when
        let content = await built(listing: listing)

        // then
        #expect(content?.accessText == "novel_freedom")
    }

    @Test func givenNoticesInTheSnapshot_whenContentIsBuilt_thenTheCountIsTheDistinctNotices() async {
        // given a duplicate that the inspector collapses
        let snapshot = task { $0["notices"] = .array([.string("first"), .string("second"), .string("first")]) }

        // when
        let content = await built(listing: task(), snapshot: snapshot)

        // then
        #expect(content?.noticeCount == 2)
        #expect(content?.hasSupervisionChip == true)
    }

    @Test func givenHealthyContinuityInTheSnapshot_whenContentIsBuilt_thenTheContinuityChipShows() async throws {
        // given
        let continuity = try #require(TaskDetailViewModelMock.continuity().task)
        var raw = continuity.raw
        raw["task_id"] = .string("abc12345")
        let snapshot = try #require(TaskInfo(.object(raw)))

        // when
        let content = await built(listing: task(), snapshot: snapshot)

        // then
        #expect(content?.showsContinuity == true)
    }

    @Test func givenAnOwnerWarningInTheSnapshot_whenContentIsBuilt_thenTheBadgeWarns() async {
        // given
        let snapshot = task { $0["supervision"] = .object(["owner_state": .string("dead")]) }

        // when
        let content = await built(listing: task(), snapshot: snapshot)

        // then
        #expect(content?.badge.label == "Running · owner lost")
    }

    @Test func givenNonDrawnMetadata_whenContentIsBuiltTwice_thenTheContentIsEqual() async {
        // given usage, summary and turn count never reach the content
        let first = await built(listing: task())
        let second = await built(listing: task {
            $0["summary"] = .string("More activity")
            $0["usage"] = .object(["output_tokens": .number(900)])
            $0["num_turns"] = .number(9)
        })

        // when / then
        #expect(first != nil)
        #expect(first == second)
    }

    // MARK: - Chip helper

    @Test(arguments: [true, false])
    func givenAContinuityModel_whenChipsAreMade_thenTheyCarryTheFactsAndAccess(narrow: Bool) throws {
        // given
        let mock = TaskDetailViewModelMock.continuity(notices: ["One", "Two"])
        let task = try #require(mock.task)

        // when
        let chips = TaskTopBarChips.make(task: task, model: mock.inspectorModel, isNarrow: narrow)

        // then
        #expect(chips.showsContinuity)
        #expect(chips.noticeCount == 2)
        #expect(chips.accessText == "Can edit this repo")
        #expect(chips.isNarrow == narrow)
    }

    @Test func givenNoInspectorModel_whenChipsAreMade_thenOnlyTheAccessChipCanShow() throws {
        // given
        let task = try #require(TaskDetailViewModelMock.continuity().task)

        // when
        let chips = TaskTopBarChips.make(task: task, model: nil, isNarrow: false)

        // then
        #expect(!chips.showsContinuity)
        #expect(chips.noticeCount == 0)
        #expect(chips.accessText != nil)
    }

    @Test(arguments: ["pending", "queued"])
    func givenAPendingTask_whenChipsAreMade_thenThereIsNoAccessChip(raw: String) throws {
        // given
        var object = try #require(TaskDetailViewModelMock.continuity().task).raw
        object["status"] = .string(raw)
        let task = try #require(TaskInfo(.object(object)))

        // when
        let chips = TaskTopBarChips.make(task: task, model: nil, isNarrow: false)

        // then
        #expect(chips.accessText == nil)
    }

    @Test func givenNoFreedom_whenChipsAreMade_thenThereIsNoAccessChip() throws {
        // given
        var object = try #require(TaskDetailViewModelMock.continuity().task).raw
        object["freedom"] = nil
        let task = try #require(TaskInfo(.object(object)))

        // when / then
        #expect(TaskTopBarChips.make(task: task, model: nil, isNarrow: false).accessText == nil)
    }

    @Test func givenTheSameTask_whenContentAndChipsAreBuilt_thenTheyAgree() async throws {
        // given
        let snapshot = task { $0["notices"] = .array([.string("n")]) }
        let content = await built(listing: task(), snapshot: snapshot)

        // when
        let chips = try #require(content).chips(isNarrow: false)

        // then
        #expect(chips.noticeCount == 1)
        #expect(chips.accessText == "Read-only")
    }
}
