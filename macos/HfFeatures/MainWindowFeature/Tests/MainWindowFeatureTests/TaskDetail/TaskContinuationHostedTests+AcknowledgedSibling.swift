import AppKit
import HfRepository
@testable import MainWindowFeature
import Testing

// MARK: - TaskContinuationHostedTests + AcknowledgedSibling

extension TaskContinuationHostedTests {
    @Test func givenAcknowledgedB_whenRecordedSiblingCBecomesCurrent_thenAcknowledgementNeverUnlocksSiblingComposer() async throws {
        // given
        let fixture = HostedContinuationFixture()
        let page = fixture.mount()
        defer { fixture.close(page) }
        await prepareDraft(fixture, page: page)
        let continueButton = try #require(page.element("task-state-continue"))
        #expect(page.press(continueButton))
        await page.settle { fixture.runner.latch.arrived.value }
        await fixture.runner.latch.release()
        await page.settle { page.element("New session accepted") != nil }
        let request = TaskContinuationRequest(runtime: fixture.runtime, conversationID: fixture.sourceID, sourceTaskID: fixture.sourceID)
        let attempt = try #require(fixture.owner.state(for: request))
        // when — both B and C have A as predecessor. C is recorded, but its path never contains acknowledged B.
        fixture.pages.result = .success(HostedContinuationPages.page(["accepted-session", "sibling-session"]))
        fixture.installMember("accepted-session")
        fixture.installMember("sibling-session")
        let acknowledged = HostedContinuationFixture.task(id: "accepted-session", status: "running", predecessor: fixture.sourceID)
        let sibling = HostedContinuationFixture.task(id: "sibling-session", status: "running", predecessor: fixture.sourceID)
        fixture.publish([HostedContinuationFixture.task(), acknowledged, sibling])
        await page.settle { fixture.vm.sut.currentTaskID == "sibling-session" }
        await fixture.owner.check(attemptID: attempt.id, targetSourceTaskID: "sibling-session")
        await page.settle { fixture.owner.state(for: request)?.permitsRecordedSource("sibling-session") == true }
        // then
        #expect(fixture.owner.state(for: request)?.permitsRecordedSource("sibling-session") == true)
        #expect(fixture.vm.sut.currentTaskID == "sibling-session")
        #expect(fixture.vm.sut.continuationPresentation?.phase == .accepted)
        #expect(fixture.vm.sut.messageBoxModel.isLocked)
        #expect(page.element("New session accepted") != nil)
        #expect(MessageBoxTranscriptStyleHostedTests.editableField(in: page) == nil)
        await assertSingleLaunch(fixture)
        try await capture(page, name: "accepted-sibling-remains-locked")
    }
}
