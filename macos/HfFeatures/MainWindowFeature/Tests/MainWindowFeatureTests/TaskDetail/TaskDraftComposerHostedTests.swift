import AppKit
import Combine
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - TaskDraftComposerHostedTests

/// The composer's external draft binding and the standalone task view keeping its unsent message across
/// navigation, mounted for real in a window: the field's own text is what is asserted.
@MainActor @Suite(.serialized)
struct TaskDraftComposerHostedTests {
    static let multiline = "  first line\n\tsecond line with trailing spaces   \n"

    // MARK: Fixtures

    @MainActor final class Submissions {
        var accepts = true
        private(set) var sent: [String] = []
        private(set) var sentNow: [String] = []
        func submit(_ text: String) -> Bool { sent.append(text); return accepts }
        func submitNow(_ text: String) -> Bool { sentNow.append(text); return accepts }
    }

    @MainActor final class Rig {
        let coordinator: MainWindowCoordinator
        private let listing: Listing

        final class Listing {
            var tasks: [TaskInfo]
            init(_ tasks: [TaskInfo]) { self.tasks = tasks }
        }

        init(_ tasks: [TaskInfo]) {
            let listing = Listing(tasks)
            self.listing = listing
            let repository = MockTaskListRepository()
            given(repository).hasListed.willReturn(true)
            given(repository).listError.willReturn(nil)
            given(repository).tasks.willProduce { listing.tasks }
            given(repository).tasksPublisher().willReturn(Empty<[TaskInfo], Never>(completeImmediately: false).eraseToAnyPublisher())
            given(repository).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
            given(repository).listErrorPublisher().willReturn(Just<ToolError?>(nil).eraseToAnyPublisher())
            self.coordinator = MainWindowCoordinator(parent: MockCoordinator(), taskListRepository: repository)
        }

        func relist(_ tasks: [TaskInfo]) {
            listing.tasks = tasks
            coordinator.reconcileDrafts()
        }
    }

    static func task(_ id: String, parent: String? = nil, minute: Int) -> TaskInfo {
        var raw: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string("claude"), "status": .string("completed"),
            "started_at": .string(String(format: "2026-09-30T10:%02d:00Z", minute))
        ]
        if let parent { raw["parent_task_id"] = .string(parent) }
        return TaskInfo(.object(raw))!
    }

    static let enabledModel = MessageBoxTranscriptStyleHostedTests.enabledModel

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: External binding

    private struct ComposerHarness: View {
        let mount: TaskDraftMount
        let style: MessageBoxStyle
        let submissions: Submissions
        var body: some View {
            MessageBoxView(model: TaskDraftComposerHostedTests.enabledModel, onSubmitNow: submissions.submitNow, style: style,
                           text: mount.text, onSubmit: submissions.submit)
        }
    }

    private func mountedComposer(style: MessageBoxStyle, submissions: Submissions) async throws
        -> (page: RedesignHost, mount: TaskDraftMount, field: NSTextField, rig: Rig) {
        let rig = Rig([Self.task("a", minute: 1)])
        let mount = rig.coordinator.draftMount(for: "a")
        let page = RedesignHost(ComposerHarness(mount: mount, style: style, submissions: submissions)
            .environment(\.hfReduceMotionOverride, true), size: CGSize(width: 900, height: 300))
        page.window.makeKeyAndOrderFront(nil)
        await page.settle { MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        return (page, mount, field, rig)
    }

    @Test(arguments: [MessageBoxStyle.standard, .transcript])
    func givenAnExternalBinding_whenTypedAndAdmitted_thenTheBindingGetsTheExactBytesAndSendClearsIt(style: MessageBoxStyle) async throws {
        // given
        let submissions = Submissions()
        let (page, mount, field, rig) = try await mountedComposer(style: style, submissions: submissions)
        defer { page.close() }
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: page)
        #expect(Self.bytes(mount.text.wrappedValue) == Self.bytes(Self.multiline))
        #expect(rig.coordinator.draftStore.storedCount == 1)
        await page.settle { page.element("Send").map { TaskStoppingHostedTests.isEnabled($0) == true } ?? false }

        // when
        let send = try #require(page.element("Send"))
        #expect(page.press(send))
        await page.settle { field.stringValue.isEmpty }

        // then
        #expect(submissions.sent.map(Self.bytes) == [Self.bytes(Self.multiline)])
        #expect(mount.text.wrappedValue.isEmpty)
        #expect(rig.coordinator.draftStore.storedCount == 0)
    }

    @Test(arguments: [MessageBoxStyle.standard, .transcript])
    func givenAnExternalBinding_whenSendIsRefused_thenTheBindingKeepsTheExactBytes(style: MessageBoxStyle) async throws {
        // given
        let submissions = Submissions()
        submissions.accepts = false
        let (page, mount, field, rig) = try await mountedComposer(style: style, submissions: submissions)
        defer { page.close() }
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: page)
        await page.settle { page.element("Send").map { TaskStoppingHostedTests.isEnabled($0) == true } ?? false }

        // when
        let send = try #require(page.element("Send"))
        #expect(page.press(send))
        await page.settle { !submissions.sent.isEmpty }

        // then
        #expect(submissions.sent.count == 1)
        #expect(Self.bytes(mount.text.wrappedValue) == Self.bytes(Self.multiline))
        #expect(Self.bytes(field.stringValue) == Self.bytes(Self.multiline))
        #expect(rig.coordinator.draftStore.storedCount == 1)
    }

    @Test(arguments: [MessageBoxStyle.standard, .transcript])
    func givenAnExternalBinding_whenSendNowIsAdmittedOrRefused_thenItClearsOrKeepsTheDraft(style: MessageBoxStyle) async throws {
        // given
        let submissions = Submissions()
        let (page, mount, field, _) = try await mountedComposer(style: style, submissions: submissions)
        defer { page.close() }
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: page)
        await page.settle { page.element("Send now").map { TaskStoppingHostedTests.isEnabled($0) == true } ?? false }
        submissions.accepts = false

        // when — refused
        #expect(page.press(try #require(page.element("Send now"))))
        await page.settle { submissions.sentNow.count == 1 }

        // then
        #expect(Self.bytes(mount.text.wrappedValue) == Self.bytes(Self.multiline))

        // when — admitted
        submissions.accepts = true
        #expect(page.press(try #require(page.element("Send now"))))
        await page.settle { field.stringValue.isEmpty }

        // then
        #expect(submissions.sentNow.map(Self.bytes) == [Self.bytes(Self.multiline), Self.bytes(Self.multiline)])
        #expect(mount.text.wrappedValue.isEmpty)
    }

    // MARK: Navigation

    @MainActor @Observable final class Navigation {
        var showsTask = true
        @ObservationIgnored var shellEvaluations = 0
    }

    /// The navigation shell: the task branch is built by the coordinator's draft seam on every evaluation, exactly
    /// like `buildTaskDetailView`, and unmounted when another destination is selected.
    struct ShellHarness: View {
        let navigation: Navigation
        let build: () -> AnyView
        var body: some View {
            navigation.shellEvaluations += 1
            return Group {
                if navigation.showsTask { build() } else { Text("Pending launches") }
            }
        }
    }

    @MainActor final class TaskHarness {
        let rig: Rig
        let navigation = Navigation()
        let mock: TaskDetailViewModelMock
        let page: RedesignHost

        init(rig: Rig, conversation id: String, mock: TaskDetailViewModelMock = .finished()) {
            self.rig = rig
            self.mock = mock
            let navigation = navigation
            let build: () -> AnyView = { [coordinator = rig.coordinator] in
                let (key, members) = coordinator.conversationKeyAndMembers(for: id)
                let draft = coordinator.draftMount(key: key, members: members) { id }
                return TaskDetailView(mock, chrome: .standalone, transcriptStyle: .transcript, draft: draft)
                    .environment(\.hfReduceMotionOverride, true)
                    .id(key)
.eraseToAnyView()
            }
            self.page = RedesignHost(ShellHarness(navigation: navigation, build: build), size: CGSize(width: 1100, height: 760))
            page.window.makeKeyAndOrderFront(nil)
        }

        var field: NSTextField? { MessageBoxTranscriptStyleHostedTests.editableField(in: page) }

        func awaitField() async throws -> NSTextField {
            await page.settle { self.field != nil }
            return try #require(field)
        }

        func leave() async {
            navigation.showsTask = false
            await page.settle { self.field == nil && self.page.element("Pending launches") != nil }
        }

        func returnToTask() async throws -> NSTextField {
            navigation.showsTask = true
            return try await awaitField()
        }

        func press(_ label: String) async throws {
            await page.settle { self.page.element(label).map { TaskStoppingHostedTests.isEnabled($0) == true } ?? false }
            #expect(page.press(try #require(page.element(label))))
        }
    }

    @Test func givenATypedMultilineDraft_whenLeavingForPendingLaunchesAndBack_thenTheFieldIsByteIdentical() async throws {
        // given
        let rig = Rig([Self.task("a1", minute: 1), Self.task("a2", parent: "a1", minute: 2)])
        let harness = TaskHarness(rig: rig, conversation: "a1")
        defer { harness.page.close() }
        let field = try await harness.awaitField()
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: harness.page)

        // when
        await harness.leave()
        let returned = try await harness.returnToTask()

        // then
        #expect(Self.bytes(returned.stringValue) == Self.bytes(Self.multiline))
    }

    @Test func givenARestoredDraft_whenAdmittedThenRefused_thenAdmittedClearsAndRefusedKeeps() async throws {
        // given
        let rig = Rig([Self.task("a1", minute: 1)])
        let harness = TaskHarness(rig: rig, conversation: "a1")
        defer { harness.page.close() }
        let field = try await harness.awaitField()
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: harness.page)
        await harness.leave()
        _ = try await harness.returnToTask()

        // when — refused by the view model
        harness.mock.acceptsMessages = false
        try await harness.press("Send")
        await harness.page.settle { harness.mock.submitted.count == 1 }
        await harness.leave()
        let kept = try await harness.returnToTask()

        // then
        #expect(Self.bytes(kept.stringValue) == Self.bytes(Self.multiline))

        // when — admitted
        harness.mock.acceptsMessages = true
        try await harness.press("Send")
        await harness.page.settle { kept.stringValue.isEmpty }
        await harness.leave()
        let cleared = try await harness.returnToTask()

        // then
        #expect(harness.mock.submitted.map(Self.bytes) == [Self.bytes(Self.multiline), Self.bytes(Self.multiline)])
        #expect(cleared.stringValue.isEmpty)
        #expect(rig.coordinator.draftStore.storedCount == 0)
    }

    @Test func givenADraftInOneConversation_whenAnotherConversationIsOpened_thenItsComposerIsEmpty() async throws {
        // given
        let rig = Rig([Self.task("a1", minute: 1), Self.task("z", minute: 2)])
        let first = TaskHarness(rig: rig, conversation: "a1")
        let field = try await first.awaitField()
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: first.page)
        first.page.close()

        // when
        let second = TaskHarness(rig: rig, conversation: "z")
        defer { second.page.close() }
        let other = try await second.awaitField()

        // then
        #expect(other.stringValue.isEmpty)
        #expect(rig.coordinator.draftStore.storedCount == 1)
    }

    @Test func givenALockedComposer_whenTheTaskIsRevisited_thenTheDraftIsStillThereOnceItIsEditableAgain() async throws {
        // given
        let rig = Rig([Self.task("a1", minute: 1)])
        let editable = TaskHarness(rig: rig, conversation: "a1")
        let field = try await editable.awaitField()
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: editable.page)
        editable.page.close()

        // when — the same conversation is opened while messages are off
        let lockedMock = TaskDetailViewModelMock.finished()
        lockedMock.messageBoxModel = MessageBoxTranscriptStyleHostedTests.lockedModel
        let locked = TaskHarness(rig: rig, conversation: "a1", mock: lockedMock)
        await locked.page.settle { locked.page.element(MessageBoxDisabledReason.takenOver.text) != nil }
        #expect(locked.field == nil)
        locked.page.close()

        // then
        let again = TaskHarness(rig: rig, conversation: "a1")
        defer { again.page.close() }
        #expect(Self.bytes(try await again.awaitField().stringValue) == Self.bytes(Self.multiline))
    }

    // MARK: Mounted transitions

    @Test func givenAnOpenTask_whenItsEarliestMemberIsPruned_thenTheComposerKeepsAndKeepsStoringTheDraft() async throws {
        // given
        let first = Self.task("a1", minute: 1)
        let second = Self.task("a2", parent: "a1", minute: 2)
        let rig = Rig([first, second])
        let harness = TaskHarness(rig: rig, conversation: "a1")
        defer { harness.page.close() }
        let field = try await harness.awaitField()
        await MessageBoxTranscriptStyleHostedTests.type("before the prune", into: field, in: harness.page)

        // when
        rig.relist([second])
        await MessageBoxTranscriptStyleHostedTests.type("before the prune, and after", into: field, in: harness.page)

        // then
        #expect(rig.coordinator.draftMount(for: "a2").text.wrappedValue == "before the prune, and after")
        #expect(harness.field?.stringValue == "before the prune, and after")
    }

    @Test func givenAnOpenTaskWhoseConversationDisappears_whenItReturns_thenTheDraftIsStillTheSame() async throws {
        // given
        let tasks = [Self.task("a1", minute: 1), Self.task("a2", parent: "a1", minute: 2)]
        let rig = Rig(tasks)
        let harness = TaskHarness(rig: rig, conversation: "a1")
        defer { harness.page.close() }
        let field = try await harness.awaitField()
        await MessageBoxTranscriptStyleHostedTests.type(Self.multiline, into: field, in: harness.page)

        // when
        rig.relist([Self.task("z", minute: 9)])
        rig.relist(tasks)
        await harness.leave()
        let returned = try await harness.returnToTask()

        // then
        #expect(Self.bytes(returned.stringValue) == Self.bytes(Self.multiline))
    }

    @Test func givenAnOpenComposerLosingAJoin_whenReconciled_thenItRebindsToTheWinnerWithoutMergingText() async throws {
        // given
        let taskB = Self.task("b", parent: "a", minute: 2)
        let taskC = Self.task("c", parent: "a", minute: 3)
        let rig = Rig([taskB, taskC])
        let harness = TaskHarness(rig: rig, conversation: "b")
        defer { harness.page.close() }
        let field = try await harness.awaitField()
        await MessageBoxTranscriptStyleHostedTests.type("draft in b", into: field, in: harness.page)
        let other = rig.coordinator.draftMount(for: "c")
        other.text.wrappedValue = "draft in c"
        let loser = rig.coordinator.draftMount(for: "b").cell

        // when
        rig.relist([Self.task("a", minute: 1), taskB, taskC])
        await harness.page.settle { harness.field?.stringValue == "draft in c" }

        // then
        #expect(harness.field?.stringValue == "draft in c")
        #expect(loser.text == "draft in b")
        #expect(rig.coordinator.draftStore.isShadowed(loser))
    }

    @Test func givenTyping_whenTheComposerChanges_thenTheNavigationShellIsNotReevaluated() async throws {
        // given
        let rig = Rig([Self.task("a1", minute: 1)])
        let harness = TaskHarness(rig: rig, conversation: "a1")
        defer { harness.page.close() }
        let field = try await harness.awaitField()
        var passes = 0
        await harness.page.settle { passes += 1; return passes >= 10 }
        let before = harness.navigation.shellEvaluations

        // when
        await MessageBoxTranscriptStyleHostedTests.type("one", into: field, in: harness.page)
        await MessageBoxTranscriptStyleHostedTests.type("one two", into: field, in: harness.page)
        await MessageBoxTranscriptStyleHostedTests.type("one two three", into: field, in: harness.page)

        // then
        #expect(harness.navigation.shellEvaluations == before)
        #expect(rig.coordinator.draftMount(for: "a1").text.wrappedValue == "one two three")
    }
}
