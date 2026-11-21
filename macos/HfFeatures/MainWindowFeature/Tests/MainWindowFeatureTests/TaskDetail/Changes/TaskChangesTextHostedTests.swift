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

/// Hosted behaviour of the Changes tab's second half over preview models.
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

    private func buttons(_ host: PaneHost, matching label: String) -> [NSObject] {
        uniqueElements(host.allElements).filter {
            host.string($0, "accessibilityLabel") == label
                && host.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
        }
    }

    private func uniqueElements(_ elements: [NSObject]) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return elements.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func sendKey(_ host: PaneHost, keyCode: UInt16, characters: String) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: host.page.window.windowNumber, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode) else { return }
        NSApp.sendEvent(event)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        host.page.host.layoutSubtreeIfNeeded()
    }

    private func moveKeyboardFocus(_ host: PaneHost, to label: String, limit: Int = 120) -> Bool {
        host.page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0 ..< limit {
            if host.focusedLabel == label { return true }
            sendKey(host, keyCode: 48, characters: "\t")
        }
        return host.focusedLabel == label
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
        let isButton = host.string(dimmed, "accessibilityRole") == NSAccessibility.Role.button.rawValue
        let pressed = host.page.press(dimmed)
        await host.pump()

        // then
        #expect(!isButton)
        #expect(!pressed)
        #expect(mock.changesSelection == nil)
    }

    @Test(arguments: [false, true])
    func givenTheSamePathInTwoScopes_whenOneSelectorIsRestored_thenOnlyThatExactRowIsExpanded(working: Bool) async throws {
        // given: src/app.py is present in committed and working-tree scopes.
        let mock = try ChangesTextMocks.mock(working: working)
        let host = await mount(mock)
        defer { host.close() }

        // then
        let matching = uniqueElements(host.allElements).filter {
            host.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && host.string($0, "accessibilityLabel")?.contains("src/app.py") == true
        }
        #expect(matching.count == 2)
        let expanded = try #require(matching.first { host.string($0, "accessibilityValue") == "Expanded" })
        let collapsed = try #require(matching.first { host.string($0, "accessibilityValue") == "Collapsed" })
        #expect(texts(host).contains(working ? "src/app.py, Working tree" : "src/app.py, Committed"))
        let expandedFrame = try #require(host.page.frame(expanded))
        let collapsedFrame = try #require(host.page.frame(collapsed))
        let diffHeader = try #require(host.page.element(working ? "src/app.py, Working tree" : "src/app.py, Committed"))
        let diffHeaderFrame = try #require(host.page.frame(diffHeader))
        if working {
            #expect(collapsedFrame.minY > expandedFrame.maxY && expandedFrame.minY > diffHeaderFrame.maxY,
                    "working-tree disclosure follows its equal-path committed sibling")
        } else {
            #expect(expandedFrame.minY > diffHeaderFrame.maxY && diffHeaderFrame.minY > collapsedFrame.maxY,
                    "committed disclosure appears before its equal-path working-tree sibling")
        }
    }

    @Test func givenASelectionInACollapsedRepositoryPastTheRevealLimit_whenRestored_thenTheRepositoryAndExactRowOpen() async throws {
        // given: the selected row is beyond the first repository's visible rows and beyond its own scope reveal limit.
        let selectedPath = "file-204.txt"
        let first = ChangesJSON.repository(root: "/workspace/first", committed: ChangesJSON.committed(rows: [ChangesJSON.row("first.txt")]),
                                           working: nil)
        let second = ChangesJSON.repository(root: "/workspace/second", committed: ChangesJSON.committed(rows: ChangesJSON.rows(205)),
                                            working: nil)
        let snapshot = try ChangesJSON.snapshot(ChangesJSON.page(repositories: [first, second], limit: 500), limit: 500)
        let built = TaskChangesPresentationBuilder.built(snapshot, taskID: PaneMocks.taskID)
        let mock = ChangesPaneMocks.mock(built)
        let selector = TaskChangesSelector(repositoryRoot: "/workspace/second", scope: .committedRange,
                                           pathBytes: Data(selectedPath.utf8))!
        mock.changesSelection = TaskChangesSelection(taskID: PaneMocks.taskID, selector: selector)
        mock.changesDiff = .loading(TaskChangesDiffHeader(path: selectedPath, scope: "Committed"))

        // when
        let host = await mount(mock)
        defer { host.close() }

        let repository = try #require(host.header("second"))
        #expect(host.string(repository, "accessibilityValue") == "Expanded")
        let scope = try #require(mock.changesRevealLimits.keys.first { $0.taskID == PaneMocks.taskID && $0.repository == 1 })
        #expect(mock.changesRevealLimits[scope] == 205)
        let outer = try #require(host.paneScrollViews().max {
            ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
        })
        let document = try #require(outer.documentView)
        let clip = outer.contentView
        let bottom = max(0, document.bounds.maxY - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottom))
        outer.reflectScrolledClipView(clip)
        await host.pump()
        await host.page.settle {
            host.allElements.contains {
                host.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                    && host.string($0, "accessibilityLabel")?.contains(selectedPath) == true
            }
        }

        // then
        let selected = try #require(host.allElements.first {
            host.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && host.string($0, "accessibilityLabel")?.contains(selectedPath) == true
        })
        #expect(host.string(selected, "accessibilityValue") == "Expanded")
        #expect(host.page.element("Reading diff") != nil)
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

    @Test func givenASelectedDiff_whenDrawn_thenTheRowAnnouncesExpansionAndTheDiffUsesThePaneScrollWithoutInnerScroll() async throws {
        // given
        let mock = try ChangesTextMocks.mock()
        let host = await mount(mock)
        defer { host.close() }

        // then
        let row = try #require(buttons(host, matching: "modified, src/app.py, 1 added, 0 removed").first)
        let view = try #require(diffTextView(host))
        #expect(host.string(row, "accessibilityValue") == "Expanded")
        #expect(!view.isEditable && view.isSelectable)
        #expect(view.enclosingScrollView != nil, "the text belongs to the pane's outer scroll view")
        #expect(host.allViews(host.page.host).compactMap { $0 as? NSScrollView }.allSatisfy { $0.documentView !== view },
                "the selectable text has no nested scroll view of its own")
        let rowFrame = try #require(host.page.frame(row))
        let diffFrame = view.convert(view.bounds, to: nil)
        #expect(diffFrame.maxY <= rowFrame.minY, "the expanded patch is immediately below its addressed file row")
        let nextSibling = try #require(uniqueElements(host.allElements).first {
            host.string($0, "accessibilityLabel")?.contains("assets/logo.png") == true
        })
        let nextSiblingFrame = try #require(host.page.frame(nextSibling))
        #expect(nextSiblingFrame.maxY < diffFrame.minY, "the patch stays above the next file row")
    }

    @Test func givenAnOpenDiff_whenItsRepositoryIsCollapsed_thenSelectionAndInlineContentAreCleared() async throws {
        // given
        let mock = try ChangesTextMocks.mock()
        let host = await mount(mock)
        defer { host.close() }
        let header = try #require(uniqueElements(host.allElements).first {
            host.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && host.string($0, "accessibilityValue") == "Expanded"
                && host.string($0, "accessibilityLabel")?.hasPrefix("repo") == true
        })

        // when
        #expect(host.page.press(header))
        await host.page.settle { host.string(header, "accessibilityValue") == "Collapsed" }

        // then
        #expect(mock.changesSelection == nil)
        #expect(mock.changesDiff == .none)
        #expect(diffTextView(host) == nil)
    }

    @Test func givenANearLimitUnbrokenDiff_whenMeasuredAtItsAvailableWidth_thenItWrapsAndCopiesUnchangedText() async throws {
        // given: a stored patch close to the public 64 KiB limit, with one unbroken line.
        let patch = "@@ -1 +1 @@\n+" + String(repeating: "x", count: 63_900)
        let host = await mount(try ChangesTextMocks.mock(state: "truncated", reason: "file_limit", bytes: Data(patch.utf8)))
        defer { host.close() }
        await host.page.settle { diffTextView(host)?.string.count ?? 0 > 60_000 }
        let originalSelection = NSRange(location: 32, length: 8)
        let initialView = try #require(diffTextView(host))
        initialView.setSelectedRange(originalSelection)

        // when
        for size in [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800)] {
            host.resize(to: size)
            await host.pump()
            host.page.host.layoutSubtreeIfNeeded()
            let view = try #require(diffTextView(host))
            let original = view.string
            #expect(view.selectedRange() == originalSelection, "text selection survives live width changes")
            #expect(original == patch, "visual wrapping does not insert characters into the captured patch")
            #expect((original as NSString).substring(with: originalSelection) == String(repeating: "x", count: originalSelection.length))
            let layout = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            #expect(view.bounds.height + 2 >= used.maxY + 2 * TaskChangesDiffText.verticalInset,
                    "the native view bounds contain every laid-out wrapped line")

            let lastCharacter = (original as NSString).length - 1
            let lastGlyph = layout.glyphRange(forCharacterRange: NSRange(location: lastCharacter, length: 1), actualCharacterRange: nil)
            let lastLine = layout.lineFragmentRect(forGlyphAt: lastGlyph.location, effectiveRange: nil)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            view.scrollRangeToVisible(NSRange(location: lastCharacter, length: 1))
            await host.pump()
            #expect(view.visibleRect.contains(lastLine), "scrolling the pane reaches the last wrapped line")
            if let outer = view.enclosingScrollView, let document = outer.documentView {
                #expect(outer.contentView.documentVisibleRect.contains(view.convert(lastLine, to: document)),
                        "the outer pane clip can display the end of the stored text")
            } else {
                Issue.record("the selectable patch must use the pane's outer scroll view")
            }

            // then
            #expect(original.utf8.count >= 63_000)
            #expect(view.isSelectable && !view.isEditable)
            #expect(view.textContainer?.widthTracksTextView == true)
            #expect(!view.isHorizontallyResizable)
            #expect(view.enclosingScrollView != nil)
            #expect(host.allViews(host.page.host).compactMap { $0 as? NSScrollView }.allSatisfy { $0.documentView !== view })
            #expect(view.selectedRange() == originalSelection)
        }
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
        let mock = try ChangesTextMocks.mock()
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

    @Test func givenARowWithoutStoredText_whenListed_thenItStaysDescriptiveWithoutASelectedDiff() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        mock.changesDiff = .none

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        let all = texts(host)
        #expect(all.contains { $0.contains("assets/logo.png") && $0.contains("Binary") })
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
    func givenARetryableFailure_whenDrawn_thenRetryRemainsSeparateAndActivationShowsLoading(kind: TaskChangesDiffBuilder.Failure) async throws {
        // given
        let mock = try ChangesTextMocks.mock()
        mock.changesDiff = .failure(ChangesTextMocks.header, kind.note)

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        let retry = try #require(button(host, "Retry"))
        #expect(host.page.press(retry))
        #expect(mock.changesDiff == .loading(ChangesTextMocks.header))
        #expect(host.page.element("Reading diff") != nil)
        #expect(button(host, "Retry") == nil)
    }

    @Test func givenRetryHasNativeFocus_whenActivated_thenFocusReturnsToItsExactFileRow() async throws {
        // given
        let mock = try ChangesTextMocks.mock()
        mock.changesDiff = .failure(ChangesTextMocks.header, TaskChangesDiffBuilder.Failure.clientBound.note)
        let host = await mount(mock)
        defer { host.close() }
        let row = try #require(buttons(host, matching: "modified, src/app.py, 1 added, 0 removed").first)
        let retry = try #require(button(host, "Retry"))
        let rowLabel = try #require(host.string(row, "accessibilityLabel"))
        #expect(moveKeyboardFocus(host, to: "Retry"), "native Tab traversal reaches Retry")
        #expect(host.focusedLabel == "Retry", "Retry owns native focus before activation")

        // when: native focus is already on Retry; activate that focused button.
        #expect(host.page.press(retry))
        await host.page.settle { mock.changesDiff == .loading(ChangesTextMocks.header) && host.focusedLabel == rowLabel }

        // then
        #expect(mock.changesDiff == .loading(ChangesTextMocks.header))
        #expect(button(host, "Retry") == nil)
        #expect(host.focusedLabel == rowLabel)
    }

    @Test func givenTheUserMovedFocusAwayFromRetry_whenRetryDisappears_thenFocusIsNotStolen() async throws {
        // given
        let mock = try ChangesTextMocks.mock()
        mock.changesDiff = .failure(ChangesTextMocks.header, TaskChangesDiffBuilder.Failure.clientBound.note)
        let host = await mount(mock)
        defer { host.close() }
        let row = try #require(buttons(host, matching: "modified, src/app.py, 1 added, 0 removed").first)
        let retry = try #require(button(host, "Retry"))
        #expect(moveKeyboardFocus(host, to: "Events"))
        #expect(host.focusedLabel == "Events")

        // when: assistive activation executes Retry while native focus remains elsewhere.
        #expect(host.page.press(retry))
        await host.page.settle { mock.changesDiff == .loading(ChangesTextMocks.header) }

        // then
        #expect(button(host, "Retry") == nil)
        #expect(host.focusedLabel == "Events")
        #expect(host.focusedLabel != host.string(row, "accessibilityLabel"))
    }

    @Test func givenRowFocus_whenTheListingChangesButItsSelectorRemains_thenFocusStaysWithThatRow() async throws {
        // given
        let mock = try ChangesTextMocks.mock()
        let host = await mount(mock)
        defer { host.close() }
        let oldRow = try #require(buttons(host, matching: "modified, src/app.py, 1 added, 0 removed").first)
        let oldLabel = try #require(host.string(oldRow, "accessibilityLabel"))
        #expect(moveKeyboardFocus(host, to: oldLabel))

        // when: a new listing changes the row value but keeps its exact member, repository, scope and path identity.
        let committed = ChangesJSON.committed(rows: [
            ChangesJSON.row("README.md", status: "added", additions: 1, deletions: 0),
            ChangesJSON.row("docs/guide.md", status: "added", additions: 1, deletions: 0),
            ChangesJSON.row("src/app.py", status: "modified", additions: 7, deletions: 2),
            ChangesJSON.row("assets/logo.png", status: "added", additions: nil, deletions: nil, binary: true, content: "binary")
        ])
        let working = ChangesJSON.working(rows: [ChangesJSON.row("src/app.py", additions: 1, deletions: 0)])
        let snapshot = try ChangesJSON.snapshot(ChangesJSON.page(task: PaneMocks.taskID,
                                                                 repositories: [ChangesJSON.repository(committed: committed, working: working)]))
        let replacement = TaskChangesPresentationBuilder.built(snapshot, taskID: PaneMocks.taskID)
        mock.changesPresentation = replacement.presentation

        // then
        let newLabel = "modified, src/app.py, 7 added, 2 removed"
        await host.page.settle { host.focusedLabel == newLabel }
        #expect(host.focusedLabel == newLabel, "the exact selector retains focus across a listing revision")
    }
}
