import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - ChangesPatchScript

/// A scripted `readChangesPatch` for the view model. Calls are recorded with their selector and fence; an action can run
/// while a call is in flight (the producer runs inline on the main actor), so a result can arrive after the view model has
/// moved on.
final class ChangesPatchScript: @unchecked Sendable {

    enum Reply {
        case text(String)
        case bytes(Data)
        case truncated(String, reason: String)
        case failure(TaskChangesReadFailure.Outcome)
        /// A patch keyed with another generation than the one requested.
        case wrongKey(String)
    }

    struct Call {
        let key: TaskChangesKey
        let selector: TaskChangesSelector
        let fence: @Sendable () -> Bool
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var replies: [Int: Reply] = [:]
    private var actions: [Int: @MainActor @Sendable () -> Void] = [:]
    private var fallback: Reply = .text(ChangesJSON.sampleDiff)

    var calls: [Call] { lock.withLock { recorded } }
    var count: Int { lock.withLock { recorded.count } }
    var isEmpty: Bool { lock.withLock { recorded.isEmpty } }

    func answer(_ index: Int, _ reply: Reply) { lock.withLock { replies[index] = reply } }
    func answerFromNowOn(_ reply: Reply) { lock.withLock { fallback = reply } }
    func whileInFlight(_ index: Int, _ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { actions[index] = action } }

    func serve(_ key: TaskChangesKey, _ selector: TaskChangesSelector, _ fence: @escaping @Sendable () -> Bool)
        -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure> {
        let (index, action) = lock.withLock { () -> (Int, (@MainActor @Sendable () -> Void)?) in
            let index = recorded.count
            recorded.append(Call(key: key, selector: selector, fence: fence))
            return (index, actions[index])
        }
        if let action { MainActor.assumeIsolated { action() } }
        let reply = lock.withLock { replies[index] ?? fallback }
        func patch(_ bytes: Data, state: String = "available", reason: String? = nil, taskID: String) -> TaskChangesPatch? {
            try? ChangesJSON.patch(selector, bytes: bytes, state: state, reason: reason, task: taskID)
        }
        let unreadable = TaskChangesReadFailure(key: key, outcome: .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "script")))
        switch reply {
        case .failure(let outcome): return .failure(TaskChangesReadFailure(key: key, outcome: outcome))
        case .text(let text):
            return patch(Data(text.utf8), taskID: key.taskID).map { .success(TaskChangesRead(key: key, value: $0)) } ?? .failure(unreadable)
        case .bytes(let data):
            return patch(data, taskID: key.taskID).map { .success(TaskChangesRead(key: key, value: $0)) } ?? .failure(unreadable)
        case .truncated(let text, let reason):
            return patch(Data(text.utf8), state: "truncated", reason: reason, taskID: key.taskID)
                .map { .success(TaskChangesRead(key: key, value: $0)) } ?? .failure(unreadable)
        case .wrongKey(let text):
            let wrong = TaskChangesKey(taskID: key.taskID, generation: key.generation + 100)
            return patch(Data(text.utf8), taskID: key.taskID).map { .success(TaskChangesRead(key: wrong, value: $0)) } ?? .failure(unreadable)
        }
    }
}

// MARK: - Rig

@MainActor
extension TaskDetailVMTests {

    struct TextRig {
        let rig: ChangesRig
        let patches: ChangesPatchScript
        var sut: TaskDetailVM { rig.sut }
        var listing: ChangesReadScript { rig.script }
    }

    /// A rig whose pane is open with the available listing applied, and a scripted patch reader.
    func openTextRig(paneOpen: Bool = true, reply: ChangesReadScript.Reply? = nil) async throws -> TextRig {
        let rig = try await openChangesRig(reply: reply ?? .snapshot(try ChangesJSON.availableListing()))
        let patches = ChangesPatchScript()
        given(rig.harness.useCase).readChangesPatch(key: .any, selector: .any, operationIsCurrent: .any).willProduce { key, selector, fence in
            patches.serve(key, selector, fence)
        }
        if paneOpen {
            rig.sut.setPaneOpen(true)
            await waitUntil { rig.sut.changesTabCount == 6 }
        }
        return TextRig(rig: rig, patches: patches)
    }

    /// The model of a displayed diff.
    func shownDiff(_ sut: TaskDetailVM) -> TaskChangesDiffModel? {
        if case .diff(let model) = sut.changesDiff { model } else { nil }
    }

    func isDiffShown(_ sut: TaskDetailVM) -> Bool { shownDiff(sut) != nil }

    func isDiffFailureShown(_ sut: TaskDetailVM) -> Bool {
        if case .failure = sut.changesDiff { true } else { false }
    }
}

// MARK: - Selecting rows and reading patches

@MainActor
extension TaskDetailVMTests {

    @Test func givenARowWithStoredText_whenSelected_thenItsPatchIsReadAndTheDiffShowsUnderTheRowsHeader() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let address = ChangesJSON.selector("README.md")

        // when
        rig.sut.didSelectChangesRow(address)

        // then: the row is selected at once and the diff is loading under its header
        let header = TaskChangesDiffHeader(path: "README.md", scope: "Committed")
        #expect(rig.sut.changesSelection == TaskChangesSelection(taskID: "t1", selector: address))
        #expect(rig.sut.changesDiff == .loading(header))
        await waitUntil { isDiffShown(rig.sut) }
        let model = try #require(shownDiff(rig.sut))
        #expect(rig.patches.count == 1)
        #expect(rig.patches.calls[0].key.taskID == "t1")
        #expect(rig.patches.calls[0].selector == address)
        #expect(model.header == header)
        #expect(model.drawnKinds == [0, 0, 0, 1, 4, 2])
        #expect(model.drawnLines.last == "+y")
        #expect(model.notice == nil && model.tail == nil && model.caption == nil)
    }

    @Test(arguments: [("assets/logo.png", "Binary"), ("notes.txt", "Name only")])
    func givenARowWithoutStoredText_whenSelected_thenNothingIsReadAndItsLabelShows(path: String, label: String) async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let scope: TaskChangesScopeName = path == "notes.txt" ? .workingTree : .committedRange

        // when
        rig.sut.didSelectChangesRow(ChangesJSON.selector(path, scope: scope))

        // then
        let header = TaskChangesDiffHeader(path: path, scope: scope == .workingTree ? "Working tree" : "Committed")
        #expect(rig.sut.changesDiff == .noText(header, label: label))
        #expect(rig.sut.changesSelection?.selector.pathBytes == Data(path.utf8))
        await waitUntil(timeout: 0.3) { !rig.patches.isEmpty }
        #expect(rig.patches.isEmpty)
    }

    @Test func givenARowThatTheListingDoesNotHold_whenSelected_thenNothingHappens() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.didSelectChangesRow(ChangesJSON.selector("ghost.txt"))

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == .none)
        #expect(rig.patches.isEmpty)
    }

    @Test func givenAReadInFlight_whenAnotherRowIsSelected_thenThePreviousReadIsCancelledAndItsLateResultNeverApplies() async throws {
        // given: the first read answers after the second row was selected; the second read answers with a dropped key
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let sut = rig.sut
        let second = ChangesJSON.selector("src/app.py")
        rig.patches.answer(0, .text("@@ -1 +1 @@\n+STALE\n"))
        rig.patches.answer(1, .wrongKey("@@ -1 +1 @@\n+NEVER\n"))
        rig.patches.whileInFlight(0) { sut.didSelectChangesRow(second) }

        // when
        rig.sut.didSelectChangesRow(ChangesJSON.selector("README.md"))
        await waitUntil { rig.patches.count == 2 }
        await waitUntil(timeout: 0.3) { isDiffShown(rig.sut) }

        // then: only the stale or the dropped result could have been shown; neither is
        #expect(rig.sut.changesDiff == .loading(TaskChangesDiffHeader(path: "src/app.py", scope: "Committed")))
        #expect(rig.sut.changesSelection?.selector == second)
        #expect(!rig.patches.calls[0].fence())
        #expect(rig.patches.calls[1].fence())
    }

    @Test func givenTheSameRowSelectedAgainWhileShown_whenSelected_thenItIsNotReadAgain() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let address = ChangesJSON.selector("README.md")
        rig.sut.didSelectChangesRow(address)
        await waitUntil { isDiffShown(rig.sut) }

        // when
        rig.sut.didSelectChangesRow(address)
        await waitUntil(timeout: 0.3) { rig.patches.count > 1 }

        // then
        #expect(rig.patches.count == 1)
        #expect(isDiffShown(rig.sut))
    }

    @Test func givenAPathInBothScopes_whenEachIsSelected_thenTwoReadsAddressTwoSelectorsAndOnlyTheWorkingTreeCarriesTheCaption() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        let committed = ChangesJSON.selector("src/app.py")
        let working = ChangesJSON.selector("src/app.py", scope: .workingTree)

        // when
        rig.sut.didSelectChangesRow(committed)
        await waitUntil { isDiffShown(rig.sut) }
        let first = try #require(shownDiff(rig.sut))
        rig.sut.didSelectChangesRow(working)
        await waitUntil { shownDiff(rig.sut)?.header.scope == "Working tree" }
        let second = try #require(shownDiff(rig.sut))

        // then
        #expect(rig.patches.calls.map(\.selector) == [committed, working])
        #expect(first.header == TaskChangesDiffHeader(path: "src/app.py", scope: "Committed") && first.caption == nil)
        #expect(second.header == TaskChangesDiffHeader(path: "src/app.py", scope: "Working tree"))
        #expect(second.caption == TaskChangesDiffBuilder.workingTreeCaption)
    }

    @Test func givenNonUTF8Text_whenRead_thenTheDiffShowsTheBytesNotice() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .bytes(Data("@@ -1 +1 @@\n+".utf8) + Data([0xFF, 0xFE, 0x0A])))

        // when
        rig.sut.didSelectChangesRow(ChangesJSON.selector("README.md"))
        await waitUntil { isDiffShown(rig.sut) }

        // then
        #expect(shownDiff(rig.sut)?.notice == "Bytes, not UTF-8")
    }

    @Test func givenATruncatedPatch_whenRead_thenTheDiffEndsWithTheTail() async throws {
        // given
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .truncated(ChangesJSON.sampleDiff, reason: "file_limit"))

        // when
        rig.sut.didSelectChangesRow(ChangesJSON.selector("README.md"))
        await waitUntil { isDiffShown(rig.sut) }

        // then
        #expect(shownDiff(rig.sut)?.tail == "Stored text ends here \u{B7} 64 KiB of a larger patch")
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded])
    func givenAGroupOrEmbeddedMount_whenARowIsSelected_thenNothingIsReadOrSelected(chrome: TaskDetailChrome) async throws {
        // given
        let rig = try await openChangesRig(chrome: chrome)
        defer { rig.sut.didDisappear() }

        // when
        rig.sut.didSelectChangesRow(ChangesJSON.selector("README.md"))
        rig.sut.restoreChangesSelection(TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("README.md")))

        // then
        #expect(rig.sut.changesSelection == nil)
        #expect(rig.sut.changesDiff == .none)
    }

    @Test func givenAShownDiff_whenItsTextIsDescribed_thenNeitherTheViewModelStateNorTheLogsHoldIt() async throws {
        // given
        let secret = "SECRET-DIFF-CONTENT"
        let rig = try await openTextRig()
        defer { rig.sut.didDisappear() }
        rig.patches.answer(0, .text("@@ -1 +1 @@\n+\(secret)\n"))

        // when
        rig.sut.didSelectChangesRow(ChangesJSON.selector("README.md"))
        await waitUntil { isDiffShown(rig.sut) }

        // then: the text is in the diff model's lines and nowhere that prints
        #expect(shownDiff(rig.sut)?.drawnLines.contains("+" + secret) == true)
        let printed = [String(describing: rig.sut.changesDiff), String(reflecting: rig.sut.changesDiff),
                       String(describing: rig.sut.changesSelection as Any), String(describing: rig.patches.calls.map(\.key)),
                       String(describing: rig.sut.changesPresentation)]
        for text in printed {
            #expect(!text.contains(secret))
        }
    }
}
