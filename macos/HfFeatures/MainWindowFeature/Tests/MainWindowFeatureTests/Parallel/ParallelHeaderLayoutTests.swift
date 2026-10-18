import AppKit
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ParallelHeaderLayoutTests

@MainActor @Suite(.serialized) struct ParallelHeaderLayoutTests {
    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)])
    func givenTwoLineGroupHeader_whenWindowResizes_thenTextHasClearanceAndActivityStaysInViewport(_ size: CGSize) async throws {
        // given
        let vm = ParallelViewModelMock(
            groupName: "pi-tracking-impl",
            headerSubtitle: "3 agents · 1 running · 2 done · Full access, Read-only · Carousell-Android, Carousell-iOS · started 19.50",
            statusSummary: "1 running · 2 done",
            headerPills: [], headerClaimCaption: "Enforced for every agent here: Network: not controlled."
        )
        let fixture = RedesignHost(NavigationSplitView {
            Text("Sidebar").frame(maxWidth: .infinity, maxHeight: .infinity)
        } detail: { ParallelView(vm) }, size: size)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element(vm.groupName) != nil }
        for nextSize in [size, CGSize(width: 1000, height: 620)] {
            fixture.window.setContentSize(nextSize)
            await fixture.settle { fixture.host.bounds.size == nextSize }
            let title = try #require(fixture.element(vm.groupName))
            let subtitle = try #require(fixture.element(vm.headerSubtitle))
            let titleFrame = try #require(fixture.frame(title))
            let subtitleFrame = try #require(fixture.frame(subtitle))
            let content = fixture.window.contentLayoutRect
            // then: real text bounds remain inset beneath window chrome and above activity.
            #expect(content.maxY - titleFrame.maxY >= 10)
            #expect(titleFrame.minY > subtitleFrame.maxY)
            #expect(fixture.element(vm.statusSummary!) == nil, "Status must share the description line")
            let scroll = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first { $0.hasHorizontalScroller })
            // AX frames use window coordinates; the hosting view itself can be flipped.
            let scrollFrame = scroll.convert(scroll.bounds, to: nil)
            #expect(subtitleFrame.minY - scrollFrame.maxY >= 10)
            #expect(scrollFrame.minY >= -1)
            #expect(scrollFrame.maxY <= content.maxY)
            #expect(scrollFrame.height > 100)
            let windowElements = fixture.elements(in: fixture.window)
            #expect(windowElements.contains { fixture.matches($0, "View prompt") })
            #expect(windowElements.contains { fixture.matches($0, "Cancel all") })
        }
    }
}

@Suite struct ParallelHeaderDescriptionTests {
    @Test(arguments: [nil, "", "1 running · 1 done"] as [String?])
    func givenStatusCounts_whenFormattingDescription_thenTotalsAndCountsPrecedeMetadata(_ status: String?) throws {
        // given
        let tasks = try ["a", "b"].map { id in
            try #require(TaskInfo(.object(["task_id": .string(id), "backend": .string("codex"),
                                          "status": .string("completed"), "repo_path": .string("/tmp/repo"),
                                          "freedom": .string("read_only")])))
        }
        // when
        let text = ParallelHeader.subtitle(tasks.map { Conversation(members: [$0]) }, startedAt: nil, statusSummary: status)
        // then
        let expected = status.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
        #expect(text == "2 agents\(expected) · Read-only · repo")
    }
}
