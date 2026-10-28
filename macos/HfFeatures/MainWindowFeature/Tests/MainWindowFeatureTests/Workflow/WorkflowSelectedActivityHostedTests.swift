import AppKit
import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - WorkflowSelectedActivityHostedTests

@MainActor @Suite(.serialized) struct WorkflowSelectedActivityHostedTests {
    @Test(arguments: [220.0, 320.0, 420.0, 500.0])
    func givenNarrowInspector_whenSelectingAnotherConversation_thenOneFittingVerticalFeedOwnsLeases(width: Double) async throws {
        // given
        let tests = ParallelVMTests()
        let harness = tests.makeSUT()
        let sut = harness.sut.makeWorkflowActivity()
        let tasks = [tests.task(id: "a"), tests.task(id: "b")]
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.itemsBox.value["a"] = [PreviewFixtures.textItem("First conversation activity")]
        harness.itemsBox.value["b"] = [PreviewFixtures.textItem("Second conversation activity")]
        harness.availabilityBox.value = ["a": .available, "b": .available]
        sut.didAppear()
        let fixture = RedesignHost(WorkflowSelectedActivityView(activity: sut), size: CGSize(width: width, height: 650))
        defer { sut.didDisappear(); fixture.close() }
        harness.tasksSubject.send(tasks)
        await fixture.settle { sut.columns.count == 2 && sut.leasedMemberCount == 1 && sut.isPresentationSettled }
        sut.selectConversation("a")
        await fixture.settle { sut.isPresentationSettled && fixture.element("First conversation activity") != nil }
        let picker = try #require(fixture.element("workflow-activity-conversation-picker"))
        #expect(fixture.frame(picker)?.width ?? .infinity <= width)
        assertVerticalFeedsFit(fixture, width: width)

        // when: geometry stays unchanged while the selection changes.
        sut.selectConversation("b")
        await fixture.settle { sut.isPresentationSettled && fixture.element("Second conversation activity") != nil }

        // then
        #expect(sut.selectedConversationID == "b")
        #expect(sut.leasedMemberCount == 1)
        #expect(sut.residentColumnCount == 1)
        #expect(harness.releasedBox.value.contains("a"))
        #expect(fixture.element("First conversation activity") == nil)
        assertVerticalFeedsFit(fixture, width: width)
    }

    private func assertVerticalFeedsFit(_ fixture: RedesignHost, width: Double) {
        let scrolls = fixture.descendants.compactMap { $0 as? NSScrollView }
        #expect(!scrolls.isEmpty)
        for scroll in scrolls {
            #expect(!scroll.hasHorizontalScroller)
            #expect(scroll.contentView.bounds.width <= width + 1)
            #expect((scroll.documentView?.bounds.width ?? 0) <= scroll.contentView.bounds.width + 1)
            #expect(abs(scroll.contentView.bounds.origin.x) < 1)
        }
    }
}
