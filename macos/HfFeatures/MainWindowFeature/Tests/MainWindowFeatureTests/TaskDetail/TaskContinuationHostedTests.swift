import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskContinuationHostedTests

@MainActor @Suite(.serialized) struct TaskContinuationHostedTests {
    static let draft = "Keep this exact draft — including punctuation."
    static let acceptedBody = "The engine accepted the request. It may still be waiting for resources; acceptance does not mean completion."
    static let unknownBody = "The engine did not report back after Continue, so a task may exist. Don't resend yet."

    @Test(arguments: [false, true], [588, 1000] as [CGFloat])
    func givenMountedDraft_whenContinueAcknowledgesBeforeRecording_thenActualButtonsLockUntilRecordedAdoption(dark: Bool, width: CGFloat) async throws {
        // given
        let fixture = HostedContinuationFixture()
        let page = fixture.mount(width: width, dark: dark)
        defer { fixture.close(page) }
        await prepareDraft(fixture, page: page)
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        let originalOwner = table.owner
        let oldContinue = originalOwner?.actions.onStateContinue
        let oldCheck = originalOwner?.actions.onStateCheck
        let button = try #require(page.element("task-state-continue"))
        // when — a real mounted button reaches the shared owner and public ctl boundary.
        #expect(page.press(button))
        await page.settle { fixture.runner.latch.arrived.value }
        await page.settle { page.element("Starting…") != nil }
        #expect(page.window.attachedSheet == nil)
        let starting = try #require(page.element("Starting…"))
        #expect(TaskStoppingHostedTests.isEnabled(starting) == false)
        _ = page.press(button)
        fixture.vm.sut.didTapContinue(taskID: fixture.sourceID)
        await assertSingleLaunch(fixture)
        #expect(fixture.vm.sut.messageBoxModel.isLocked)
        let observationCount = TaskDetailVMTests.Box(0)
        fixture.fixtures.successorObservationEffect.value = { _ in
            observationCount.value += 1
            throw ToolError.notFound(tool: "fixture successors", searched: [])
        }
        await fixture.runner.latch.release()
        await page.settle { page.element("New session accepted") != nil && observationCount.value > 0 }
        // then — acknowledgement is not a running status or an adopted member.
        #expect(fixture.vm.sut.currentTaskID == fixture.sourceID)
        #expect(fixture.vm.sut.task?.status == .failed)
        #expect(fixture.vm.sut.messageBoxModel.isLocked)
        #expect(page.element(Self.acceptedBody) != nil)
        #expect(table.owner === originalOwner)
        try assertVisibleText(Self.acceptedBody, in: page)
        try await capture(page, name: "accepted-pending-\(Int(width))-\(dark ? "dark" : "light")")
        // when — positive public recorded evidence and ordinary conversation adoption arrive.
        fixture.pages.result = .success(HostedContinuationPages.page(["accepted-session"]))
        let request = TaskContinuationRequest(runtime: fixture.runtime, conversationID: fixture.sourceID, sourceTaskID: fixture.sourceID)
        let attempt = try #require(fixture.owner.state(for: request))
        let successor = HostedContinuationFixture.task(id: "accepted-session", status: "running", predecessor: fixture.sourceID)
        fixture.installMember("accepted-session")
        let observedBeforeRetry = observationCount.value
        fixture.fixtures.successorObservationEffect.value = { _ in
            observationCount.value += 1
            fixture.members.value = [HostedContinuationFixture.task(), successor]
            return false
        }
        fixture.publishFreshStatusRead()
        await page.settle { observationCount.value > observedBeforeRetry }
        #expect(observationCount.value > observedBeforeRetry)
        await page.settle { fixture.vm.sut.currentTaskID == "accepted-session" && !fixture.vm.sut.messageBoxModel.isLocked }
        try await assertRestoredComposer(page)
        #expect(fixture.vm.sut.task?.status == .running)
        #expect(table.owner === originalOwner)
        let readsBeforeStaleCallbacks = fixture.pages.readCount
        oldContinue?(fixture.sourceID)
        oldCheck?(fixture.sourceID, attempt.id)
        await page.settle { fixture.vm.sut.currentTaskID == "accepted-session" }
        #expect(fixture.pages.readCount == readsBeforeStaleCallbacks)
        await assertSingleLaunch(fixture)
        try await capture(page, name: "accepted-adopted-\(Int(width))-\(dark ? "dark" : "light")")
    }

    @Test func givenUnknownOutcome_whenActualCheckReturnsEmptyThenFails_thenComposerStaysLockedAndContinueNeverReplays() async throws {
        // given
        let fixture = HostedContinuationFixture(result: .failure(.timedOut(tool: "fixture ctl", seconds: 1)))
        let page = fixture.mount()
        defer { fixture.close(page) }
        await prepareDraft(fixture, page: page)
        let button = try #require(page.element("task-state-continue"))
        #expect(page.press(button))
        await page.settle { fixture.runner.latch.arrived.value }
        await fixture.runner.latch.release()
        await page.settle { page.element("A new session may have started") != nil }
        #expect(page.element(Self.unknownBody) != nil)
        // when
        let readsBeforeEmptyCheck = fixture.pages.readCount
        let check = try #require(page.element("task-state-check"))
        #expect(page.press(check))
        await page.settle { fixture.pages.readCount > readsBeforeEmptyCheck && fixture.vm.sut.continuationPresentation?.isChecking == false }
        #expect(fixture.pages.readCount > readsBeforeEmptyCheck)
        #expect(fixture.vm.sut.messageBoxModel.isLocked)
        fixture.pages.result = .failure(.notFound(tool: "fixture successors", searched: []))
        let readsBeforeFailure = fixture.pages.readCount
        let nextCheck = try #require(page.element("task-state-check"))
        #expect(page.press(nextCheck))
        await page.settle { fixture.pages.readCount > readsBeforeFailure && fixture.vm.sut.continuationPresentation?.isChecking == false }
        #expect(fixture.pages.readCount > readsBeforeFailure)
        // then
        #expect(fixture.vm.sut.messageBoxModel.isLocked)
        #expect(fixture.vm.sut.currentTaskID == fixture.sourceID)
        #expect(page.element(Self.unknownBody) != nil)
        let launches = await fixture.runner.continueCount
        #expect(launches == 1)
        try await capture(page, name: "unknown-after-check-failure")
        try await assertUncertainNativeMenu(fixture)
        // when — feature-owned conversation rows expose C while the owner's global list still contains only A.
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        let oldContinue = table.owner?.actions.onStateContinue
        let oldCheck = table.owner?.actions.onStateCheck
        let request = TaskContinuationRequest(runtime: fixture.runtime, conversationID: fixture.sourceID, sourceTaskID: fixture.sourceID)
        let uncertainAttempt = try #require(fixture.owner.state(for: request))
        fixture.pages.set(.success(HostedContinuationPages.page(["bridge-session"])), for: fixture.sourceID)
        fixture.pages.set(.success(HostedContinuationPages.page(["current-session"], source: "bridge-session")), for: "bridge-session")
        fixture.installMember("bridge-session")
        fixture.installMember("current-session")
        let bridge = HostedContinuationFixture.task(id: "bridge-session", status: "completed", predecessor: fixture.sourceID)
        let current = HostedContinuationFixture.task(id: "current-session", predecessor: "bridge-session")
        fixture.publish([HostedContinuationFixture.task(), bridge, current])
        await page.settle { fixture.vm.sut.currentTaskID == "current-session" && !fixture.vm.sut.messageBoxModel.isLocked }
        // then — C gets its own observed-failure treatment; A's unknown result remains retained and unchanged.
        #expect(fixture.owner.state(for: request)?.permitsRecordedSource("current-session") == true)
        #expect(fixture.owner.state(for: request)?.outcome == uncertainAttempt.outcome)
        #expect(fixture.vm.sut.continuationPresentation?.phase == .eligible)
        #expect(fixture.vm.sut.continuationPresentation?.taskID == "current-session")
        #expect(page.element("A new session may have started") == nil)
        try await revealTreatment(taskID: "current-session", in: page)
        await page.settle { page.element("Task failed: the harness exited with code 1") != nil && page.element("task-state-continue") != nil }
        #expect(page.element("Task failed: the harness exited with code 1") != nil)
        #expect(page.element("task-state-continue") != nil)
        try await assertRestoredComposer(page)
        let readsBeforeOldActions = fixture.pages.readCount
        oldContinue?(fixture.sourceID)
        oldCheck?(fixture.sourceID, uncertainAttempt.id)
        await page.settle { fixture.vm.sut.currentTaskID == "current-session" }
        #expect(fixture.pages.readCount == readsBeforeOldActions)
        let launchesAfterProof = await fixture.runner.continueCount
        #expect(launchesAfterProof == 1)
        try await capture(page, name: "unknown-recorded-descendant-adopted")
    }

    @Test func givenEngineRefusal_whenActualNewTaskPressed_thenGenericCopyRetainsRawReasonAndRoutesFresh() async throws {
        // given
        let reason = "Backend declined this exact source: session unavailable."
        let fixture = HostedContinuationFixture(result: .success(HostedContinuationCtl.response(reason: reason)))
        let page = fixture.mount()
        defer { fixture.close(page) }
        await prepareDraft(fixture, page: page)
        let button = try #require(page.element("task-state-continue"))
        #expect(page.press(button))
        await page.settle { fixture.runner.latch.arrived.value }
        await fixture.runner.latch.release()
        await page.settle { page.element("The engine refused this request.") != nil }
        // when
        #expect(page.element(reason) != nil)
        let newTask = try #require(page.element("New task"))
        #expect(page.press(newTask))
        // then
        #expect(fixture.fixtures.newTaskCount.value == 1)
        let launches = await fixture.runner.continueCount
        #expect(launches == 1)
        try await capture(page, name: "refused-with-engine-reason")
    }

    func revealTreatment(taskID: String, in page: RedesignHost) async throws {
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(page.host).first)
        func index() -> Int? {
            table.owner?.entries.firstIndex { entry in
                if case .taskState(let model, _) = entry { return model.taskID == taskID }
                return false
            }
        }
        await page.settle { index() != nil }
        let row = try #require(index())
        let scroll = try #require(table.enclosingScrollView)
        let limit = max(0, table.bounds.maxY - scroll.contentView.bounds.height)
        activityNativeTestScroll(scroll, to: min(max(0, table.rect(ofRow: row).minY), limit))
        table.layoutSubtreeIfNeeded()
    }

    func assertRestoredComposer(_ page: RedesignHost) async throws {
        await page.settle { page.element("Locked until the new session is checked") == nil }
        #expect(page.element("Locked until the new session is checked") == nil)
        let restored = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        #expect(!restored.isHiddenOrHasHiddenAncestor)
        #expect(restored.stringValue == Self.draft)
    }

    func assertSingleLaunch(_ fixture: HostedContinuationFixture) async {
        let count = await fixture.runner.continueCount
        #expect(count == 1)
    }

    func prepareDraft(_ fixture: HostedContinuationFixture, page: RedesignHost) async {
        await page.settle { fixture.vm.sut.isMounted }
        fixture.publish([HostedContinuationFixture.task(status: "running")])
        await page.settle { MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        if let field = MessageBoxTranscriptStyleHostedTests.editableField(in: page) {
            await MessageBoxTranscriptStyleHostedTests.type(Self.draft, into: field, in: page)
        }
        fixture.publish([HostedContinuationFixture.task()])
        await page.settle { page.element("task-state-continue") != nil }
    }

    func assertVisibleText(_ text: String, in page: RedesignHost) throws {
        let element = try #require(page.element(text))
        let frame = try #require(page.frame(element))
        #expect(frame.width > 0 && frame.height > 0)
        let actualBounds = page.host.convert(page.host.bounds, to: nil)
        #expect(actualBounds.insetBy(dx: -1, dy: -1).contains(frame), "Rendered notice must fit actual host geometry: \(frame), \(actualBounds)")
    }

    func capture(_ page: RedesignHost, name: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_CONTINUE_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await DisplayFrames.waitForPresentedFrame()
        await page.settle { page.hasStableRenderedFrame }
        #expect(page.hasStableRenderedFrame)
        await DisplayFrames.waitForPresentedFrame()
        page.host.layoutSubtreeIfNeeded()
        page.host.displayIfNeeded()
        let bitmap = try #require(page.host.bitmapImageRepForCachingDisplay(in: page.host.bounds))
        page.host.cacheDisplay(in: page.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
