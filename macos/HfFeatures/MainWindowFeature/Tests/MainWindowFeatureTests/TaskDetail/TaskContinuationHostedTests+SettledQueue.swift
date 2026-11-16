import AppKit
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - Settled queued messages

extension TaskContinuationHostedTests {
    @Test(arguments: [false, true], [588, 1000] as [CGFloat])
    func givenSettledQueuedMessage_whenContinuePressed_thenSingleContinuationNeverSendsMessage(dark: Bool, width: CGFloat) async throws {
        // given
        let fixture = HostedContinuationFixture()
        let page = fixture.mount(width: width, dark: dark)
        defer { fixture.close(page) }
        await prepareDraft(fixture, page: page)
        var raw = HostedContinuationFixture.task().raw
        raw["messages"] = .array([.object(["id": .string("queued-message"), "seq": .number(1),
            "status": .string("queued"), "text": .string("Queued on this finished task")])])
        fixture.publish([try #require(TaskInfo(.object(raw)))])
        await page.settle { page.element("Queued on this finished task") != nil && page.element("task-state-continue") != nil }
        // then — the approved settled surface retains Cancel and only the explicit Continue path.
        #expect(page.element("Cancel queued message") != nil)
        #expect(page.element("Send now") == nil)
        #expect(!fixture.vm.sut.messageBoxModel.showsSendNow)
        let button = try #require(page.element("task-state-continue"))
        // when
        #expect(page.press(button))
        fixture.vm.sut.didTapContinue(taskID: fixture.sourceID)
        await page.settle { fixture.runner.latch.arrived.value }
        await assertSingleLaunch(fixture)
        verify(fixture.vm.useCase).submitTypedMessage(.any, text: .any, now: .any, acknowledgingUnconfirmed: .any, context: .any).called(0)
        verify(fixture.vm.useCase).send(.any, text: .any).called(0)
        verify(fixture.vm.useCase).sendNow(.any, text: .any).called(0)
        await fixture.runner.latch.release()
    }
}
