import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ChangesPaneMocks

/// Preview-model fixtures for the Changes tab of the standalone mount: a done task whose view model carries a built presentation.
@MainActor enum ChangesPaneMocks {
    static let conversation = "conv"

    static func mock(_ built: TaskChangesBuilt) -> TaskDetailViewModelMock {
        let mock = PaneMocks.done(exit: 0)
        mock.changesPresentation = built.presentation
        mock.changesTabCount = built.tabCount
        mock.changesCaptureSettling = built.isSettling
        return mock
    }

    static func mock(_ snapshot: TaskChangesSnapshot) -> TaskDetailViewModelMock {
        mock(TaskChangesPresentationBuilder.built(snapshot))
    }

    static func store(tab: TaskPaneStateStore.Tab = .changes) -> TaskPaneStateStore {
        let store = TaskPaneStateStore()
        store.setOpenChoice(.open, for: conversation)
        store.setSelectedTab(tab, for: conversation)
        return store
    }

    /// One repository with two scopes, a long list in the first, for reveal and dimming.
    static func busySnapshot(rows: Int = 450) throws -> TaskChangesSnapshot {
        let binary = ChangesJSON.row("binary.dat", status: "added", additions: nil, deletions: nil, binary: true, content: "binary")
        let cut = ChangesJSON.row("cut/path", pathTruncated: true, additions: nil, deletions: nil, content: "not_captured", reason: "path_too_long")
        let repository = ChangesJSON.repository(
            committed: ChangesJSON.committed(rows: ChangesJSON.rows(rows) + [binary]), working: ChangesJSON.working(rows: [cut]))
        return try ChangesJSON.snapshot(ChangesJSON.page(repositories: [repository], limit: 500), limit: 500)
    }

    /// Two repositories: the first complete, the second row limited, read as two pages.
    static func multiSnapshot() throws -> TaskChangesSnapshot {
        let alphaRows = [ChangesJSON.row("a.swift"), ChangesJSON.row("b.swift", status: "added")]
        let alpha = ChangesJSON.repository(root: "/work/alpha", committed: ChangesJSON.committed(rows: alphaRows))
        let alphaAgain = ChangesJSON.repository(root: "/work/alpha", committed: ChangesJSON.committed(rowCount: 2))
        let beta = ChangesJSON.repository(
            root: "/work/beta", committed: ChangesJSON.committed(rowCount: 500, rows: ChangesJSON.rows(498), truncated: true))
        let betaRest = ChangesJSON.repository(
            root: "/work/beta", committed: ChangesJSON.committed(rowCount: 500, rows: ChangesJSON.rows(2, prefix: "rest"), truncated: true))
        return try ChangesJSON.snapshot([(ChangesJSON.page(repositories: [alpha, beta], limit: 500, cursor: "next"), 500),
                                         (ChangesJSON.page(repositories: [alphaAgain, betaRest], limit: 500), 500)])
    }
}

// MARK: - TaskChangesTabHostedTests

/// Hosted behaviour of the Changes tab over preview models: the tab count drawn or absent per state, the note states,
/// rows that are not controls, and the row reveal.
@MainActor @Suite(.serialized) struct TaskChangesTabHostedTests {

    private func mount(_ mock: TaskDetailViewModelMock, store: TaskPaneStateStore = ChangesPaneMocks.store(), dark: Bool = false) async -> PaneHost {
        let host = PaneHost(PaneMocks.standalone(mock, store: store), size: CGSize(width: 1280, height: 900), dark: dark)
        await host.page.settle { host.columnWidth != nil && host.hasPane }
        await host.pump()
        return host
    }

    /// The elements that carry a note's text, found by its title in their label or value.
    private func noteText(_ host: PaneHost, _ title: String) -> [NSObject] {
        host.allElements.filter {
            host.string($0, "accessibilityLabel")?.contains(title) == true || host.string($0, "accessibilityValue")?.contains(title) == true
        }
    }

    private func isButton(_ host: PaneHost, _ element: NSObject?) -> Bool {
        element.flatMap { host.string($0, "accessibilityRole") } == NSAccessibility.Role.button.rawValue
    }

    /// The separate button named exactly `title`.
    private func actionButton(_ host: PaneHost, _ title: String) -> NSObject? {
        host.allElements.first { host.string($0, "accessibilityLabel") == title && isButton(host, $0) }
    }

    /// Asserts a note's text is drawn as its own element that is not a control, and that its action is a separate named button.
    private func expectAction(_ host: PaneHost, title: String, action: String?, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = noteText(host, title)
        #expect(!text.isEmpty, "no element carries \(title)", sourceLocation: sourceLocation)
        #expect(text.allSatisfy { !isButton(host, $0) }, "the note text is not itself a button", sourceLocation: sourceLocation)
        if let action {
            #expect(actionButton(host, action) != nil, "no button named \(action)", sourceLocation: sourceLocation)
        } else {
            #expect(!host.allElements.contains { isButton(host, $0) && ["Retry read", "Check again"].contains(host.string($0, "accessibilityLabel")) },
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: Tab count

    @Test func givenAnAppliedCount_whenTheTabsAreDrawn_thenChangesCarriesTheCountInItsLabel() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        #expect(mock.changesTabCount == 6)
        #expect(host.page.element("Changes, 6") != nil)
        #expect(host.page.element("Changes") == nil, "the count joins the label")
    }

    @Test func givenAZeroCount_whenTheTabsAreDrawn_thenTheZeroIsShown() async throws {
        // given
        let mock = ChangesPaneMocks.mock(try ChangesJSON.zeroRows())

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        #expect(host.page.element("Changes, 0") != nil)
    }

    @Test(arguments: [0, 1, 2])
    func givenStatesWithoutACount_whenTheTabsAreDrawn_thenNoCountShows(state: Int) async throws {
        // given
        let mock: TaskDetailViewModelMock = switch state {
        case 0: ChangesPaneMocks.mock(TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.clientBound(.deadline))))
        case 1: ChangesPaneMocks.mock(try ChangesJSON.pendingSettling())
        default: ChangesPaneMocks.mock(try ChangesJSON.incomplete())
        }

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        #expect(mock.changesTabCount == nil)
        #expect(host.page.element("Changes") != nil)
    }

    // MARK: States

    @Test func givenTheLoadingState_whenDrawn_thenReadingStoredChangesShowsWithNoCount() async {
        // given
        let mock = PaneMocks.done(exit: 0)

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        let texts = host.allElements.flatMap { [host.string($0, "accessibilityLabel"), host.string($0, "accessibilityValue")] }
        #expect(texts.contains { $0?.contains("Reading stored changes") == true })
        #expect(host.page.element("Changes") != nil)
    }

    @Test func givenAnErrorNote_whenRetryIsPressed_thenTheViewModelIsAsked() async throws {
        // given
        let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.clientBound(.requestBudget)))
        let mock = ChangesPaneMocks.mock(built)
        let host = await mount(mock)
        defer { host.close() }

        // when
        expectAction(host, title: "Reading stopped early", action: "Retry read")
        let button = try #require(actionButton(host, "Retry read"))

        // then
        #expect(host.page.press(button))
    }

    @Test func givenAnUnsupportedEngine_whenDrawn_thenRetryReadIsOffered() async {
        // given
        let built = TaskChangesPresentationBuilder.build(
            taskID: "t1", outcome: .failure(.failed(.unsupportedCommand(tool: "harflow-ctl", command: "task-changes", detail: ""))))

        // when
        let host = await mount(ChangesPaneMocks.mock(built))
        defer { host.close() }

        // then
        expectAction(host, title: "This engine does not support Changes", action: "Retry read")
    }

    @Test func givenAStartedPendingLaunchRefusal_whenDrawn_thenNoActionIsOffered() async {
        // given
        let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(ChangesJSON.pendingLaunch)))

        // when
        let host = await mount(ChangesPaneMocks.mock(built))
        defer { host.close() }

        // then
        expectAction(host, title: "Available once this task starts", action: nil)
    }

    @Test func givenTheCappedSettlingNote_whenDrawn_thenCheckAgainIsOffered() async {
        // given
        let mock = PaneMocks.done(exit: 0)
        mock.changesPresentation = .settlingCapped

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        expectAction(host, title: "Stored changes aren't available yet", action: "Check again")
    }

    // MARK: Rows

    @Test func givenARow_whenDrawn_thenItIsAnAccessibleLabelledElementThatIsNotAControl() async throws {
        // given
        let host = await mount(ChangesPaneMocks.mock(try ChangesJSON.availableListing()))
        defer { host.close() }

        // when
        let row = try #require(host.page.element("modified, src/app.py, 1 added, 0 removed"))

        // then
        let role = host.string(row, "accessibilityRole")
        #expect(role != NSAccessibility.Role.button.rawValue)
        #expect(!host.page.press(row), "rows are not interactive in this stage")
    }

    @Test func givenABinaryRowAndAnUntrackedRow_whenDrawn_thenTheirLabelsCarryTheStateAndOmitMissingCounts() async throws {
        // given
        let host = await mount(ChangesPaneMocks.mock(try ChangesJSON.availableListing()))
        defer { host.close() }

        // then
        #expect(host.page.element("added, assets/logo.png, Binary") != nil)
        #expect(host.page.element("untracked, notes.txt, Name only") != nil)
    }

    @Test func givenARepositoryHeader_whenPressed_thenItCollapsesAndReopens() async throws {
        // given
        let host = await mount(ChangesPaneMocks.mock(try ChangesJSON.availableListing()))
        defer { host.close() }
        let header = try #require(host.allElements.first {
            host.string($0, "accessibilityValue") == "Expanded" && host.string($0, "accessibilityLabel")?.hasPrefix("repo") == true
        })

        // when
        #expect(host.page.press(header))
        await host.pump()

        // then
        #expect(host.page.element("added, README.md") == nil)
    }

    @Test func givenManyRepositories_whenDrawn_thenOnlyTheFirstIsOpen() async throws {
        // given
        let host = await mount(ChangesPaneMocks.mock(try ChangesPaneMocks.multiSnapshot()))
        defer { host.close() }

        // then
        let values = host.allElements.compactMap { element -> (String, String)? in
            guard let value = host.string(element, "accessibilityValue"), value == "Expanded" || value == "Collapsed" else { return nil }
            return (host.string(element, "accessibilityLabel") ?? "", value)
        }
        #expect(values.first { $0.0.hasPrefix("alpha") }?.1 == "Expanded")
        #expect(values.first { $0.0.hasPrefix("beta") }?.1 == "Collapsed")
    }

    @Test func givenManyRepositories_whenDrawn_thenTheAttributionAppearsNoMoreOftenThanForOne() async throws {
        // given: the accessibility tree repeats a text through its wrappers, so a count is compared rather than read as one
        func occurrences(_ mock: TaskDetailViewModelMock) async -> Int {
            let host = await mount(mock)
            defer { host.close() }
            let texts = host.allElements.flatMap { [host.string($0, "accessibilityLabel"), host.string($0, "accessibilityValue")] }
            return texts.filter { $0?.contains(TaskChangesRepositoryEntry.attribution) == true }.count
        }

        // when
        let single = await occurrences(ChangesPaneMocks.mock(try ChangesJSON.availableListing()))
        let multiple = await occurrences(ChangesPaneMocks.mock(try ChangesPaneMocks.multiSnapshot()))

        // then
        #expect(single > 0)
        #expect(multiple == single, "one document-level attribution, not one per repository")
    }

    // MARK: Reveal

    @Test func givenMoreRowsThanTheFirstStep_whenLoadMoreIsPressed_thenTheScopeRevealsTwoHundredMore() async throws {
        // given
        let snapshot = try ChangesPaneMocks.busySnapshot()
        let mock = ChangesPaneMocks.mock(snapshot)
        let host = await mount(mock)
        defer { host.close() }
        let scope = TaskChangesScopeID(taskID: "t1", repository: 0, scope: "committed_range")
        #expect(mock.changesRevealLimits[scope] == nil)

        // when
        let button = try #require(host.page.element("Load more rows"))
        #expect(host.page.press(button))
        await host.pump()

        // then
        #expect(mock.changesRevealLimits[scope] == 400)
    }
}
