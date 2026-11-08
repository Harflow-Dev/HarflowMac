import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - ChangesTextMocks

/// Preview-model fixtures for the second half of the Changes tab: a selected row, its diff, the turn picker.
@MainActor enum ChangesTextMocks {
    static let header = TaskChangesDiffHeader(path: "src/app.py", scope: "Committed")

    /// The available listing with the diff of `src/app.py` built from `text`.
    static func mock(
        diff text: String? = nil, state: String = "available", reason: String? = nil, working: Bool = false,
        bytes: Data? = nil
    ) throws -> TaskDetailViewModelMock {
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        let scope: TaskChangesScopeName = working ? .workingTree : .committedRange
        let address = ChangesJSON.selector("src/app.py", scope: scope)
        mock.changesSelection = TaskChangesSelection(taskID: PaneMocks.taskID, selector: address)
        let facts = TaskChangesRowFacts(path: "src/app.py", scopeTitle: working ? "Working tree" : "Committed", hasText: true, label: nil,
                                        stateHelp: nil, countsAndPatchSeparate: working)
        let patchBytes = bytes ?? Data((text ?? ChangesJSON.textCompleteText).utf8)
        let patch = try ChangesJSON.patch(address, bytes: patchBytes, state: state, reason: reason)
        mock.changesDiff = TaskChangesDiffBuilder.build(
            patch: patch, header: TaskChangesDiffHeader(path: "src/app.py", scope: facts.scopeTitle), facts: facts)
        return mock
    }

    static func turns(selected: String = "cccccccc-0003") -> TaskChangesTurnPicker? {
        TaskChangesTurnPicker.make(memberIDs: ["aaaaaaaa-0001", "bbbbbbbb-0002", "cccccccc-0003"], selectedID: selected)
    }
}

// MARK: - DiffHarness

/// An observable holder for the diff block, so a hosted test can change what the block draws.
@Observable @MainActor final class DiffBox {
    var diff: TaskChangesDiffPresentation
    init(_ diff: TaskChangesDiffPresentation) { self.diff = diff }
}

/// The diff block alone, driven by a `DiffBox`.
struct DiffHarness: View {
    let box: DiffBox

    var body: some View {
        VStack(alignment: .leading) { ChangesDiffView(diff: box.diff, perform: { _ in }) }
            .padding()
            .environment(\.hfReduceMotionOverride, true)
    }
}

// MARK: - TaskChangesTextHostedTests

/// Hosted behaviour of the Changes tab's second half over preview models: rows that select, the selection the pane remembers
/// and restores, the turn bar, and the notes that stand in for a diff.
@MainActor @Suite(.serialized) struct TaskChangesTextHostedTests {

    private func mount(_ mock: TaskDetailViewModelMock, store: TaskPaneStateStore = ChangesPaneMocks.store()) async -> PaneHost {
        let host = PaneHost(PaneMocks.standalone(mock, store: store), size: CGSize(width: 1280, height: 1100))
        await host.page.settle { host.columnWidth != nil && host.hasPane }
        await host.pump()
        return host
    }

    private func texts(_ host: PaneHost) -> [String] {
        host.allElements.flatMap { [host.string($0, "accessibilityLabel"), host.string($0, "accessibilityValue")] }.compactMap(\.self)
    }

    private func button(_ host: PaneHost, _ title: String) -> NSObject? {
        host.allElements.first {
            host.string($0, "accessibilityLabel") == title && host.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
        }
    }

    // MARK: Rows

    @Test func givenAnAddressableRow_whenPressed_thenTheViewModelSelectsItAndThePaneStoreRemembersTheSelection() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        let store = ChangesPaneMocks.store()
        let host = await mount(mock, store: store)
        defer { host.close() }
        #expect(store.changesSelection(for: ChangesPaneMocks.conversation) == nil)

        // when
        let row = try #require(host.page.element("modified, src/app.py, 1 added, 0 removed"))
        #expect(host.page.press(row))
        await host.pump()
        let selected = try #require(mock.changesSelection)
        #expect(selected.selector == ChangesJSON.selector("src/app.py"))

        // when: the preview mock is not observable, so closing the pane (store state the view does observe) re-evaluates the
        // standalone view, which then sees the new selection and records it
        let close = try #require(host.page.element("Close right pane"))
        #expect(host.page.press(close))
        await host.page.settle { store.changesSelection(for: ChangesPaneMocks.conversation) != nil }

        // then
        #expect(store.changesSelection(for: ChangesPaneMocks.conversation) == selected)
    }

    @Test func givenARememberedSelection_whenThePaneAppears_thenTheViewModelIsAskedToRestoreIt() async throws {
        // given
        let remembered = TaskChangesSelection(taskID: PaneMocks.taskID, selector: ChangesJSON.selector("README.md"))
        let store = ChangesPaneMocks.store()
        store.setChangesSelection(remembered, for: ChangesPaneMocks.conversation)
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())

        // when
        let host = await mount(mock, store: store)
        defer { host.close() }

        // then
        #expect(mock.changesSelection == remembered)
    }

    @Test func givenARowNoSelectorCanAddress_whenDrawn_thenItIsDimmedAndDisabled() async throws {
        // given
        let cut = ChangesJSON.row("cut/path", pathTruncated: true, additions: nil, deletions: nil, content: "not_captured", reason: "path_too_long")
        let repository = ChangesJSON.repository(committed: ChangesJSON.committed(rows: [cut, ChangesJSON.row("fine.txt")]))
        let snapshot = try ChangesJSON.snapshot(ChangesJSON.page(repositories: [repository]))
        let mock = ChangesPaneMocks.mock(snapshot)
        let host = await mount(mock)
        defer { host.close() }

        // when
        let dimmed = try #require(host.page.element("modified, cut/path, Path cut \u{B7} no text, 0 added, 0 removed")
            ?? host.allElements.first { host.string($0, "accessibilityLabel")?.contains("cut/path") == true })
        let pressed = host.page.press(dimmed)
        await host.pump()

        // then
        #expect(!pressed)
        #expect(mock.changesSelection == nil)
    }

    // MARK: Turn bar

    @Test func givenSeveralTurns_whenDrawn_thenTheBarNamesTheSelectedTaskAndTheCaptionSaysTurnsAreNotAddedTogether() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        mock.changesTurns = ChangesTextMocks.turns(selected: "bbbbbbbb-0002")

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        let all = texts(host)
        #expect(all.contains(TaskChangesTurnPicker.caption))
        #expect(all.contains("task bbbbbbbb"))
        #expect(texts(host).contains { $0.hasPrefix("Turn 2 of 3") }, "the menu is labelled with the selected turn")
    }

    @Test func givenASingleTurn_whenDrawn_thenThereIsNoBar() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        #expect(!texts(host).contains(TaskChangesTurnPicker.caption))
        #expect(!texts(host).contains { $0.hasPrefix("Turn ") })
    }

    // MARK: The diff block

    private func diffTextView(_ host: PaneHost, path: String = "src/app.py") -> NSTextView? {
        host.allViews(host.page.host).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Diff of \(path)" }
    }

    @Test func givenADiff_whenDrawn_thenItIsOneReadOnlySelectableTextViewWithPrefixedLinesAndAHeader() async throws {
        // given
        let host = await mount(try ChangesTextMocks.mock())
        defer { host.close() }

        // when
        let view = try #require(diffTextView(host))

        // then
        #expect(!view.isEditable && view.isSelectable)
        let lines = view.string.components(separatedBy: "\n")
        #expect(lines.count == 7)
        #expect(lines[4] == "@@ -1 +1,2 @@")
        #expect(lines[5] == " print('a')")
        #expect(lines[6] == "+print('b')")
        #expect(texts(host).contains("src/app.py, Committed"), "the header is one combined element: path, then scope tag")
    }

    @Test func givenADrawnDiff_whenTheModelChangesItToAnotherPatch_thenTheTextViewShowsTheNewText() async throws {
        // given: the diff block over an observable model, since the preview mock is not observable
        let first = try ChangesTextMocks.mock().changesDiff
        let second = try ChangesTextMocks.mock(diff: "@@ -1 +1 @@\n+SECOND\n").changesDiff
        let box = DiffBox(first)
        let host = PaneHost(DiffHarness(box: box), size: CGSize(width: 900, height: 700))
        await host.page.settle { diffTextView(host) != nil }
        defer { host.close() }
        #expect(diffTextView(host)?.string.contains("print('b')") == true)

        // when
        box.diff = second
        await host.page.settle { diffTextView(host)?.string == "@@ -1 +1 @@\n+SECOND" }

        // then
        #expect(diffTextView(host)?.string == "@@ -1 +1 @@\n+SECOND")
    }

    @Test func givenADrawnDiff_whenTheModelChangesItToTheSamePatch_thenTheTextViewKeepsItsText() async throws {
        // given
        let first = try ChangesTextMocks.mock().changesDiff
        let box = DiffBox(first)
        let host = PaneHost(DiffHarness(box: box), size: CGSize(width: 900, height: 700))
        await host.page.settle { diffTextView(host) != nil }
        defer { host.close() }
        let before = diffTextView(host)?.string

        // when
        box.diff = try ChangesTextMocks.mock().changesDiff
        await host.pump()

        // then
        #expect(diffTextView(host)?.string == before)
    }

    @Test func givenNotesOnADiff_whenDrawn_thenTheNoticesTailAndCaptionShow() async throws {
        // given: bytes that are not UTF-8 in CRLF lines, truncated, in the working tree
        let bytes = Data("@@ -1 +1 @@\r\n+caf".utf8) + Data([0xE9, 0xFF]) + Data("\r\n".utf8)
        let host = await mount(try ChangesTextMocks.mock(state: "truncated", reason: "file_limit", working: true, bytes: bytes))
        defer { host.close() }

        // then
        let all = texts(host)
        #expect(all.contains("Bytes, not UTF-8"))
        #expect(all.contains("Lines end in CRLF"))
        #expect(all.contains("Stored text ends here \u{B7} 64 KiB of a larger patch"))
        #expect(all.contains(TaskChangesDiffBuilder.workingTreeCaption))
        #expect(all.contains("Working tree"))
    }

    @Test func givenHostileCharacters_whenDrawn_thenTheTextViewShowsThemVisiblyEscaped() async throws {
        // given
        let host = await mount(try ChangesTextMocks.mock(diff: "@@ -1 +1 @@\n+a\u{202E}b\u{1B}\n"))
        defer { host.close() }

        // then
        #expect(diffTextView(host)?.string == "@@ -1 +1 @@\n+a\\u{202E}b\\x1b")
    }

    @Test func givenTheLoadingState_whenDrawn_thenTheHeaderAndASkeletonShowWithoutAnyText() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        mock.changesDiff = .loading(ChangesTextMocks.header)

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        #expect(texts(host).contains("src/app.py, Committed"))
        #expect(diffTextView(host) == nil)
        #expect(host.page.element("Reading diff") != nil, "the loading skeleton is announced")
    }

    // MARK: Notes under a row

    @Test func givenARowWithoutStoredText_whenSelected_thenItsHeaderAndLabelShowAndNoDiffBlockDoes() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        mock.changesDiff = .noText(TaskChangesDiffHeader(path: "assets/logo.png", scope: "Committed"), label: "No stored text for this row")

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        let all = texts(host)
        #expect(all.contains("No stored text for this row"))
        #expect(!all.contains { $0.hasPrefix("Diff of ") })
    }

    @Test func givenTheReloadNote_whenDrawn_thenReloadChangesIsASeparateButton() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        mock.changesDiff = .failure(ChangesTextMocks.header, TaskChangesDiffBuilder.Failure.reload.note)

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        #expect(texts(host).contains { $0.contains(TaskChangesDiffBuilder.failureTitle) })
        let reload = try #require(button(host, "Reload changes"))
        #expect(host.page.press(reload))
    }

    @Test(arguments: [TaskChangesDiffBuilder.Failure.clientBound, .other])
    func givenARetryableFailure_whenDrawn_thenRetryIsASeparateButton(kind: TaskChangesDiffBuilder.Failure) async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        mock.changesDiff = .failure(ChangesTextMocks.header, kind.note)

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        let retry = try #require(button(host, "Retry"))
        #expect(host.page.press(retry))
        #expect(texts(host).contains { $0.contains(TaskChangesDiffBuilder.failureTitle) })
    }
}
