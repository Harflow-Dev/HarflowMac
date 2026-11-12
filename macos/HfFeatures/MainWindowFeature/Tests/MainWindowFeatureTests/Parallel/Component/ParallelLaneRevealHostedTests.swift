import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - ParallelLaneRevealHostedTests

/// Keyboard reach of Parallel lanes at a minimum window: two whole 360-point lanes and a peek. Focus
/// ENTERING a lane scrolls the row the minimum distance that shows that whole lane, and the lane that
/// then comes into view becomes resident. Live Tab delivery cannot be sent by the harness, so the tests
/// make the lane's field the first responder (what Tab does) and record Tab itself as unverified.
@MainActor @Suite(.serialized) struct ParallelLaneRevealHostedTests {
    private static let detailWidth: CGFloat = 736

    @MainActor private struct Mounted {
        let fixture: RedesignHost
        let harness: ParallelVMTests.SUT
        var window: NSWindow { fixture.window }

        /// The row's horizontal scroll view: the one whose document is five lane strides wide.
        var horizontalScroll: NSScrollView? {
            fixture.descendants
.compactMap { $0 as? NSScrollView }
                .first { scroll in scroll.documentView.map { abs($0.frame.width - 5 * ParallelTestGeometry.laneStride) < 3 } == true }
        }

        /// The lane message fields, left to right.
        var fields: [NSTextField] {
            fixture.descendants
.compactMap { $0 as? NSTextField }
                .filter { $0.placeholderString == "Queue a message…" }
                .sorted { fixture.host.convert($0.bounds, from: $0).minX < fixture.host.convert($1.bounds, from: $1).minX }
        }
    }

    private func mount() async throws -> Mounted {
        let tests = ParallelVMTests()
        let harness = tests.makeSUT()
        let tasks = (0 ..< 5).map { tests.task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        let fixture = RedesignHost(ParallelView(harness.sut, initiallyPrepared: true),
                                   size: CGSize(width: Self.detailWidth, height: 620))
        harness.tasksSubject.send(tasks)
        let mounted = Mounted(fixture: fixture, harness: harness)
        await fixture.settle {
            harness.sut.columns.count == 5 && harness.sut.residentColumnCount == 3 && harness.sut.isPresentationSettled
                && mounted.fields.count == 3 && mounted.horizontalScroll != nil
        }
        try #require(harness.sut.residentColumnCount == 3, "two whole lanes and a 14 pt peek are resident")
        try #require(mounted.fields.count == 3)
        return mounted
    }

    /// Lets the run loop deliver pending focus, layout and scroll notifications (a synchronous helper, since
    /// `RunLoop.run(until:)` cannot be called directly from an async context).
    private func pump(turns: Int = 20) {
        for _ in 0 ..< turns { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }

    private func close(_ mounted: Mounted) {
        mounted.harness.sut.didDisappear()
        mounted.fixture.close()
    }

    @Test func givenMinimumWindow_whenLaneGeometryIsMeasured_thenTwoWholeLanesAndAPeekShow() async throws {
        // given / when
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)

        // then — lanes are 360 wide with a 1 pt separator: 2 * 361 = 722 of the 736, leaving a 14 pt peek.
        let stride = ParallelTestGeometry.laneStride
        #expect(stride == 361)
        #expect(scroll.contentView.bounds.width == Self.detailWidth)
        let third = mounted.fixture.host.convert(mounted.fields[2].bounds, from: mounted.fields[2])
        #expect(third.minX >= 2 * stride, "the peek lane's field lies beyond the viewport, reachable only by scrolling")
        #expect(Self.detailWidth - 2 * stride == 14)
    }

    @Test func givenThePeekLane_whenItsFieldTakesFocus_thenTheRowScrollsItWhollyIntoViewAndTheNextLaneBecomesResident() async throws {
        // given
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)
        let stride = ParallelTestGeometry.laneStride
        #expect(scroll.documentVisibleRect.minX == 0)

        // when — what Tab does: the peek lane's field becomes first responder.
        mounted.window.makeKeyAndOrderFront(nil)
        let field = mounted.fields[2]
        #expect(mounted.window.makeFirstResponder(field))
        let laneMax = 3 * stride - ParallelLayout.dividerWidth
        await mounted.fixture.settle { scroll.documentVisibleRect.maxX >= laneMax - 0.5 }

        // then — minimum distance plus the separator and 1 pt of the next lane (so that lane is geometry-resident).
        let visible = scroll.documentVisibleRect
        #expect(abs(visible.maxX - (laneMax + ParallelLayout.dividerWidth + 1)) < 1, "the lane is scrolled just fully into view: \(visible)")
        let laneFrame = CGRect(x: 2 * stride, y: 0, width: ParallelLayout.minimumColumnWidth, height: 1)
        #expect(visible.contains(laneFrame.origin) && visible.maxX >= laneFrame.maxX)

        // then — the fourth lane now intersects the viewport, so it is resident and leased.
        await mounted.fixture.settle { mounted.harness.sut.residentColumnCount == 4 && mounted.harness.sut.isPresentationSettled }
        #expect(mounted.harness.sut.residentColumnCount == 4)
        #expect(mounted.harness.sut.leasedMemberCount == 4)
    }

    @Test func givenFocusStaysInALane_whenTheUserScrollsAwayAndTheViewRerenders_thenThePositionHolds() async throws {
        // given — focus is inside the peek lane and the row has revealed it.
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)
        mounted.window.makeKeyAndOrderFront(nil)
        #expect(mounted.window.makeFirstResponder(mounted.fields[2]))
        let laneMax = 3 * ParallelTestGeometry.laneStride - ParallelLayout.dividerWidth
        await mounted.fixture.settle { scroll.documentVisibleRect.maxX >= laneMax - 0.5 }

        // when — a manual scroll back to the start, then unrelated model churn.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        mounted.harness.busySubject.send(["task-0"])
        mounted.harness.busySubject.send([])
        pump()
        mounted.fixture.host.layoutSubtreeIfNeeded()
        pump()

        // then — focus did not change lanes, so nothing pulls the row back.
        #expect(scroll.documentVisibleRect.minX < 1, "manual position holds: \(scroll.documentVisibleRect)")
    }

    @Test func givenALaneAlreadyWhollyVisible_whenItsFieldTakesFocus_thenTheRowDoesNotMove() async throws {
        // given
        let mounted = try await mount()
        defer { close(mounted) }
        let scroll = try #require(mounted.horizontalScroll)

        // when
        mounted.window.makeKeyAndOrderFront(nil)
        #expect(mounted.window.makeFirstResponder(mounted.fields[1]))
        pump()

        // then
        #expect(scroll.documentVisibleRect.minX == 0)
    }
}
