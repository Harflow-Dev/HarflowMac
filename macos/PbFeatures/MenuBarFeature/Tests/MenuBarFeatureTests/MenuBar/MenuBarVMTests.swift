import Combine
import Foundation
@testable import MenuBarFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import Testing

@MainActor
@Suite struct MenuBarVMTests {
    
    private func task(
        id: String, backend: String = "claude", status: String = "running", startedAt: Date? = .now,
        group: String? = nil, spawnedBy: String? = nil
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string(backend), "status": .string(status)
        ]
        if let startedAt { object["started_at"] = .string(ISO8601DateFormatter().string(from: startedAt)) }
        if let group { object["group"] = .string(group) }
        if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
        return TaskInfo(.object(object))!
    }
    
    /// `TaskEvent`/`TimelineItem` have no public initializer — built through the public
    /// `TaskEvent(line:)` JSON-line decoder and `Timeline.items(from:)`, same pattern as
    /// `MonitorCoreTests`' own `eventLine` helper.
    private func toolCallItem(command: String) -> TimelineItem {
        let line = #"{"v": 1, "seq": 0, "task_id": "t1", "kind": "tool_call", "call_id": "c1", "tool": "Bash", "#
        + #""category": "shell", "input_preview": "ls", "command": "\#(command)"}"#
        let event = TaskEvent(line: line)!
        return Timeline.items(from: [event])[0]
    }
    
    private func textItem(_ text: String) -> TimelineItem {
        let line = #"{"v": 1, "seq": 0, "task_id": "t1", "kind": "assistant_text", "text": "\#(text)"}"#
        let event = TaskEvent(line: line)!
        return Timeline.items(from: [event])[0]
    }
    
    /// A plain mutable box read by a `willProduce` closure registered exactly once — `Mockable`'s
    /// FIFO stub queue does not reliably swap a member's answer for the very next call when a
    /// second `given(...).willReturn(...)` is registered after the first has already been read
    /// (see the note in `GeneralSettingsVMTests`, `SettingsFeature`). Mutating a box sidesteps it.
    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    
    struct SUT {
        let sut: MenuBarVM
        let useCase: MockMenuBarUseCase
        let routing: MockMenuBarRouting
        let tasksSubject: PassthroughSubject<[TaskInfo], Never>
        let listErrorSubject: PassthroughSubject<ToolError?, Never>
        let hasListedSubject: PassthroughSubject<Bool, Never>
        let runningCountBox: Box<Int>
        let titlesSubject: PassthroughSubject<[String: String], Never>
        let titleBox: Box<(String) -> String>
        let installStateSubject: PassthroughSubject<InstallState, Never>
        let lastCheckMessageSubject: PassthroughSubject<String?, Never>
        let installAnywayBlockedMessageSubject: PassthroughSubject<String?, Never>
        let installStateBox: Box<InstallState>
        let installNeedBox: Box<InstallNeed?>
        let installDestinationBox: Box<String?>
    }

    func makeSUT(
        connectionLine: String = "connecting…",
        runningCount: Int = 0,
        openWindowOnStart: Bool = true,
        notifyOnFinish: Bool = true,
        installState: InstallState = .idle
    ) -> SUT {
        let useCase = MockMenuBarUseCase()
        let routing = MockMenuBarRouting()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let listErrorSubject = PassthroughSubject<ToolError?, Never>()
        let hasListedSubject = PassthroughSubject<Bool, Never>()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let openWindowSubject = PassthroughSubject<Bool, Never>()
        let notifySubject = PassthroughSubject<Bool, Never>()
        let runningCountBox = Box(runningCount)
        // Re-stubbing `title(_:)` a second time after this is FIFO/unreliable (the same Mockable
        // gotcha documented elsewhere in this repo), so a test that needs the title to change
        // between two reads mutates this box instead of calling `given` again.
        let titleBox = Box<(String) -> String>({ "Task \($0.prefix(8))" })
        let installStateSubject = PassthroughSubject<InstallState, Never>()
        let lastCheckMessageSubject = PassthroughSubject<String?, Never>()
        let installAnywayBlockedMessageSubject = PassthroughSubject<String?, Never>()
        let installStateBox = Box<InstallState>(installState)
        let installNeedBox = Box<InstallNeed?>(nil)
        let installDestinationBox = Box<String?>(nil)

        given(useCase).connectionLine.willReturn(connectionLine)
        given(useCase).runningCount.willProduce { runningCountBox.value }
        given(useCase).openWindowOnStart.willReturn(openWindowOnStart)
        given(useCase).notifyOnFinish.willReturn(notifyOnFinish)
        given(useCase).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(listErrorSubject.eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(hasListedSubject.eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        given(useCase).openWindowOnStartPublisher().willReturn(openWindowSubject.eraseToAnyPublisher())
        given(useCase).notifyOnFinishPublisher().willReturn(notifySubject.eraseToAnyPublisher())
        given(useCase).title(.any).willProduce { titleBox.value($0) }
        given(useCase).setOpenWindowOnStart(.any).willReturn()
        given(useCase).setNotifyOnFinish(.any).willReturn()
        given(routing).select(.any).willReturn()
        given(routing).openWindow().willReturn()
        given(routing).registerWindowOpener(.any).willReturn()

        given(useCase).installState.willProduce { installStateBox.value }
        given(useCase).installStatePublisher().willReturn(installStateSubject.eraseToAnyPublisher())
        given(useCase).lastCheckMessage.willReturn(nil)
        given(useCase).lastCheckMessagePublisher().willReturn(lastCheckMessageSubject.eraseToAnyPublisher())
        given(useCase).installAnywayBlockedMessage.willReturn(nil)
        given(useCase).installAnywayBlockedMessagePublisher().willReturn(installAnywayBlockedMessageSubject.eraseToAnyPublisher())
        given(useCase).installNeed(for: .any).willProduce { _ in installNeedBox.value }
        given(useCase).installDestination().willProduce { installDestinationBox.value }
        given(useCase).install().willReturn()
        given(useCase).installUvThenPolybridge().willReturn()
        given(useCase).retry().willReturn()
        given(useCase).checkAgain().willReturn()
        given(useCase).installAnyway().willReturn(true)
        given(useCase).reset().willReturn()

        let sut = MenuBarVM(useCase: useCase, routing: routing)
        return SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: tasksSubject, listErrorSubject: listErrorSubject,
            hasListedSubject: hasListedSubject, runningCountBox: runningCountBox, titlesSubject: titlesSubject, titleBox: titleBox,
            installStateSubject: installStateSubject, lastCheckMessageSubject: lastCheckMessageSubject,
            installAnywayBlockedMessageSubject: installAnywayBlockedMessageSubject, installStateBox: installStateBox,
            installNeedBox: installNeedBox, installDestinationBox: installDestinationBox
        )
    }
    
    // MARK: - Lists
    
    @Test func givenRootsAndSubTasksRunning_whenListed_thenRootsComeFirst() async {
        // given
        let harness = makeSUT(runningCount: 2)
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        given(useCase).runningCount.willReturn(2)
        sut.didAppear()
        let subTask = task(id: "sub1", status: "running", spawnedBy: "root1")
        let root = task(id: "root1", status: "running")
        
        // when — published in sub-task-first order; the VM must still sort roots first.
        tasksSubject.send([subTask, root])
        
        // then
        await waitUntil { sut.runningRows.count == 2 }
        #expect(sut.runningRows.map(\.id) == ["root1", "sub1"])
    }
    
    // Regression (item 6): titles resolve asynchronously, after a task first lists (Sidebar and
    // Parallel already recompute their rows when `titlesPublisher` fires) — the menu bar must too,
    // or a row is stuck on its placeholder title forever once the real one loads.
    @Test func givenTitlesLoadAfterTasksAreListed_whenTitlesPublish_thenRowsRecomputeWithTheNewTitles() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let titlesSubject = harness.titlesSubject
        let titleBox = harness.titleBox
        titleBox.value = { _ in "placeholder" }
        sut.didAppear()
        let running = task(id: "root1", status: "running")
        
        // when — the task lists before its title has resolved.
        tasksSubject.send([running])
        await waitUntil { !sut.runningRows.isEmpty }
        #expect(sut.runningRows.first?.title == "placeholder")
        
        // when — the title resolves later, with no further tasks/listError/hasListed emission.
        titleBox.value = { _ in "Real Title" }
        titlesSubject.send(["root1": "Real Title"])
        
        // then
        await waitUntil { sut.runningRows.first?.title == "Real Title" }
        #expect(sut.runningRows.first?.title == "Real Title")
    }
    
    @Test func givenMoreThanSixRecentRootsAndThreeGroups_whenListed_thenTheyAreCapped() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        var tasks: [TaskInfo] = []
        for idx in 0 ..< 8 {
            tasks.append(task(id: "root\(idx)", status: "completed", startedAt: .now.addingTimeInterval(Double(-idx))))
        }
        for groupIndex in 0 ..< 4 {
            tasks.append(task(id: "member\(groupIndex)a", status: "completed", group: "group\(groupIndex)"))
            tasks.append(task(id: "member\(groupIndex)b", status: "completed", group: "group\(groupIndex)"))
        }
        
        // when
        tasksSubject.send(tasks)
        
        // then
        await waitUntil { !sut.recentTasks.isEmpty || !sut.recentGroups.isEmpty }
        #expect(sut.recentTasks.count == 6)
        #expect(sut.recentGroups.count == 3)
    }
    
    @Test func givenTheRunningCountFromTheUseCase_whenTasksUpdate_thenItIsRepublished() async {
        // given — F4-26: every running task counts, sub-tasks included; the VM reads the count
        // straight from the use case rather than recomputing it, so this proves it stays wired.
        let harness = makeSUT(runningCount: 0)
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let runningCountBox = harness.runningCountBox
        sut.didAppear()
        runningCountBox.value = 3
        
        // when
        tasksSubject.send([task(id: "a"), task(id: "b"), task(id: "c")])
        
        // then
        await waitUntil { sut.runningCount == 3 }
        #expect(sut.runningCount == 3)
    }
    
    @Test func givenListErrorAndHasListed_whenObserved_thenIsConnectedReflectsBoth() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        
        // when
        hasListedSubject.send(true)
        listErrorSubject.send(nil)
        
        // then
        await waitUntil { sut.isConnected }
        #expect(sut.isConnected)
        #expect(sut.listErrorMessage == nil)
    }
    
    @Test func givenAListErrorThatIsNotAnInstallNeed_whenObserved_thenTheMessageShowsAndIsConnectedIsFalse() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        hasListedSubject.send(true)
        let failure = ToolError.refused(code: "denied", message: "polybridge-ctl refused the request.")

        // when
        listErrorSubject.send(failure)

        // then
        await waitUntil { sut.listErrorMessage != nil }
        #expect(sut.listErrorMessage == failure.message)
        #expect(sut.isConnected == false)
        #expect(sut.installBannerModel == nil)
    }

    // Moved from a `.message`-forwarding assertion (settled plan, section 7): a `notFound` error
    // for `polybridge-ctl`/`polybridge-setup` is an install need, so it now shows the banner instead
    // of the plain red `listErrorMessage`.
    @Test func givenAListErrorThatIsAnInstallNeed_whenObserved_thenTheBannerShowsInsteadOfTheRedText() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let listErrorSubject = harness.listErrorSubject
        let hasListedSubject = harness.hasListedSubject
        harness.installNeedBox.value = .missing
        sut.didAppear()
        hasListedSubject.send(true)
        let failure = ToolError.notFound(tool: "polybridge-ctl", searched: ["/usr/local/bin"])

        // when
        listErrorSubject.send(failure)

        // then
        await waitUntil { sut.installBannerModel != nil }
        #expect(sut.listErrorMessage == nil)
        #expect(sut.isConnected == false)
        #expect(sut.installBannerModel?.title == "polybridge isn't installed")
        #expect(sut.installBannerModel?.detail == failure.message)
        #expect(sut.installBannerModel?.primaryTitle == "Install polybridge")
    }
    
    // MARK: - Selection
    
    @Test func givenAMenuBarSelection_whenOpened_thenItSelectsAndOpensTheWindow() {
        // given — `MonitorDestination` is `Hashable`, so `verify(...).value(...)` matches directly;
        // no need to re-`given` the mock mid-test (a second `given` for the same member does not
        // reliably override `makeSUT`'s default stub before the next call, per the Mockable FIFO
        // pitfall documented in the Phase 3 report).
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing
        
        // when
        sut.didSelectRunningTask("abc123")
        
        // then
        verify(routing).select(.value(.task("abc123"))).called(1)
        verify(routing).openWindow().called(1)
    }
    
    @Test func givenAGroupSelection_whenOpened_thenItSelectsTheGroupAndOpensTheWindow() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing
        
        // when
        sut.didSelectGroup("release-notes")
        
        // then
        verify(routing).select(.value(.group("release-notes"))).called(1)
        verify(routing).openWindow().called(1)
    }
    
    @Test func givenOpenMonitorTapped_whenInvoked_thenOnlyTheWindowOpensNoSelectionChanges() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing
        
        // when
        sut.didTapOpenMonitor()
        
        // then
        verify(routing).openWindow().called(1)
        verify(routing).select(.any).called(0)
    }
    
    @Test func givenTheWindowOpenerIsCaptured_whenInvoked_thenItRegistersThroughRouting() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing
        
        // when
        sut.didCaptureWindowOpener {}
        
        // then
        verify(routing).registerWindowOpener(.any).called(1)
    }
    
    // MARK: - Settings toggles
    
    @Test func givenToggleActions_whenInvoked_thenTheyForwardToTheUseCase() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        
        // when
        sut.didToggleOpenWindowOnStart(false)
        sut.didToggleNotifyOnFinish(false)
        
        // then
        verify(useCase).setOpenWindowOnStart(.value(false)).called(1)
        verify(useCase).setNotifyOnFinish(.value(false)).called(1)
    }
    
    // MARK: - Row leases (decision 6)
    
    @Test func givenARunningRowAppears_whenALeaseIsAcquired_thenItIsReleasedOnRowDisappear() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let lease = MockEventStreamLease()
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value("abc123")).willReturn(lease)
        given(useCase).itemsPublisher(.value("abc123")).willReturn(Empty().eraseToAnyPublisher())
        
        // when
        sut.didAppearRunningRow("abc123")
        sut.didDisappearRunningRow("abc123")
        
        // then
        verify(useCase).acquireEventLease(.value("abc123")).called(1)
        verify(lease).release().called(1)
    }
    
    @Test func givenARunningRowAlreadyLeased_whenItAppearsAgain_thenItDoesNotAcquireASecondLease() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let lease = MockEventStreamLease()
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value("abc123")).willReturn(lease)
        given(useCase).itemsPublisher(.value("abc123")).willReturn(Empty().eraseToAnyPublisher())
        
        // when
        sut.didAppearRunningRow("abc123")
        sut.didAppearRunningRow("abc123")
        
        // then
        verify(useCase).acquireEventLease(.value("abc123")).called(1)
    }
    
    @Test func givenACurrentToolCall_whenItemsUpdate_thenTheActivityLineIsTheMonospacedHeadline() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        tasksSubject.send([task(id: "abc123", status: "running")])
        await waitUntil { sut.runningRows.count == 1 }
        
        let items = PassthroughSubject<[TimelineItem], Never>()
        let lease = MockEventStreamLease()
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value("abc123")).willReturn(lease)
        given(useCase).itemsPublisher(.value("abc123")).willReturn(items.eraseToAnyPublisher())
        let current = toolCallItem(command: "grep -rn login .")
        given(useCase).current(.value("abc123")).willReturn(current)
        
        // when
        sut.didAppearRunningRow("abc123")
        items.send([current])
        
        // then
        await waitUntil { sut.runningRows.first?.activityLine != nil }
        #expect(sut.runningRows.first?.activityLine == "Bash grep -rn login .")
        #expect(sut.runningRows.first?.activityIsMonospaced == true)
    }
    
    @Test func givenNoCurrentToolCall_whenTheLastItemIsText_thenTheActivityLineIsThatTextNotMonospaced() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        tasksSubject.send([task(id: "abc123", status: "running")])
        await waitUntil { sut.runningRows.count == 1 }
        
        let items = PassthroughSubject<[TimelineItem], Never>()
        let lease = MockEventStreamLease()
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value("abc123")).willReturn(lease)
        given(useCase).itemsPublisher(.value("abc123")).willReturn(items.eraseToAnyPublisher())
        given(useCase).current(.value("abc123")).willReturn(nil)
        
        // when
        sut.didAppearRunningRow("abc123")
        items.send([textItem("Looking at the tokenizer next.")])
        
        // then
        await waitUntil { sut.runningRows.first?.activityLine != nil }
        #expect(sut.runningRows.first?.activityLine == "Looking at the tokenizer next.")
        #expect(sut.runningRows.first?.activityIsMonospaced == false)
    }
    
    // MARK: - Teardown (judgement call, see MenuBarVM's header comment)
    
    @Test func givenDidDisappear_whenCalled_thenPerRowLeasesReleaseButCoreDataStaysLive() async {
        // given — the core subscription must survive the popover closing, so the label's running
        // count keeps updating; only the per-row leases are released.
        let harness = makeSUT()
        let sut = harness.sut
        let useCase = harness.useCase
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        tasksSubject.send([task(id: "abc123", status: "running")])
        await waitUntil { sut.runningRows.count == 1 }
        let lease = MockEventStreamLease()
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value("abc123")).willReturn(lease)
        given(useCase).itemsPublisher(.value("abc123")).willReturn(Empty().eraseToAnyPublisher())
        sut.didAppearRunningRow("abc123")
        
        // when
        sut.didDisappear()
        tasksSubject.send([task(id: "abc123", status: "running"), task(id: "def456", status: "running")])
        
        // then
        verify(lease).release().called(1)
        await waitUntil { sut.runningRows.count == 2 }
        #expect(sut.runningRows.count == 2)
    }
}
