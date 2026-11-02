import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - ScrollRevealScheduleTests

@MainActor @Suite struct ScrollRevealScheduleTests {
    private final class Clock {
        var now: TimeInterval = 100
    }

    private func makeSchedule(_ clock: Clock) -> ScrollRevealSchedule {
        ScrollRevealSchedule(lingerDuration: 1.5, clock: { clock.now })
    }

    @Test func givenNewSchedule_whenQueried_thenItDoesNotReveal() {
        // given
        let schedule = makeSchedule(Clock())

        // when / then
        #expect(!schedule.shouldReveal())
    }

    @Test func givenHovering_whenTimePasses_thenItKeepsRevealing() {
        // given
        let clock = Clock()
        var schedule = makeSchedule(clock)
        schedule.enter()

        // when
        clock.now += 60

        // then
        #expect(schedule.shouldReveal())
    }

    @Test func givenExit_whenBeforeAndAfterLingerDeadline_thenRevealsOnlyUntilDeadline() {
        // given
        let clock = Clock()
        var schedule = makeSchedule(clock)
        schedule.enter()

        // when
        schedule.exit()
        clock.now += 1.4
        let beforeDeadline = schedule.shouldReveal()
        clock.now += 0.2
        let afterDeadline = schedule.shouldReveal()

        // then
        #expect(beforeDeadline)
        #expect(!afterDeadline)
    }

    @Test func givenExit_whenReenteredBeforeDeadline_thenDeadlineClearsAndRevealHasNoGap() {
        // given
        let clock = Clock()
        var schedule = makeSchedule(clock)
        schedule.enter()
        schedule.exit()
        clock.now += 1

        // when
        schedule.enter()
        let reentered = schedule.shouldReveal()
        clock.now += 5

        // then
        #expect(reentered)
        #expect(schedule.lingerDeadline == nil)
        #expect(schedule.shouldReveal())
    }

    @Test func givenStaleHover_whenWindowIsNotKey_thenHoverEndsAndLingers() {
        // given
        let clock = Clock()
        var schedule = makeSchedule(clock)
        schedule.enter()

        // when
        schedule.refresh(pointerInside: true, windowIsKey: false)

        // then
        #expect(!schedule.isHovering)
        #expect(schedule.shouldReveal())
        clock.now += 2
        #expect(!schedule.shouldReveal())
    }

    @Test func givenStaleHover_whenPointerIsOutside_thenHoverEnds() {
        // given
        var schedule = makeSchedule(Clock())
        schedule.enter()

        // when
        schedule.refresh(pointerInside: false, windowIsKey: true)

        // then
        #expect(!schedule.isHovering)
    }

    @Test func givenValidHover_whenRefreshed_thenHoverContinues() {
        // given
        var schedule = makeSchedule(Clock())
        schedule.enter()

        // when
        schedule.refresh(pointerInside: true, windowIsKey: true)

        // then
        #expect(schedule.isHovering)
        #expect(schedule.lingerDeadline == nil)
    }
}

// MARK: - ScrollHoverRevealTests

@MainActor @Suite(.serialized) struct ScrollHoverRevealTests {
    private final class Counter {
        var flashes = 0
    }

    private final class Clock {
        var now: TimeInterval = 100
    }

    private final class Pointer {
        var location: NSPoint? = NSPoint(x: 50, y: 90)
        var windowIsKey = true
    }

    private struct Rig {
        let owner: ScrollHoverRevealOwner
        let scroll: NSScrollView
        let window: NSWindow
        let counter: Counter
        let clock: Clock
        let pointer: Pointer
    }

    private func makeRig(withScroller: Bool = false) -> Rig {
        _ = NSApplication.shared
        let counter = Counter()
        let clock = Clock()
        let pointer = Pointer()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        if withScroller {
            scroll.scrollerStyle = .overlay
            scroll.hasHorizontalScroller = true
            scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        }
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        let owner = ScrollHoverRevealOwner(
            flash: { _ in counter.flashes += 1 },
            schedule: ScrollRevealSchedule(lingerDuration: 1.5, clock: { clock.now }),
            pointerState: { _ in .init(location: pointer.location, windowIsKey: pointer.windowIsKey) }
        )
        owner.attach(to: scroll)
        return Rig(owner: owner, scroll: scroll, window: window, counter: counter, clock: clock, pointer: pointer)
    }

    @Test func givenAttachedHoveringOwner_whenTicked_thenItFlashesOnEveryTick() {
        // given
        let rig = makeRig()
        defer { rig.owner.detach(); rig.window.contentView = nil; rig.window.close() }
        rig.owner.pointerEntered()

        // when
        rig.owner.tick()
        rig.owner.tick()
        rig.owner.tick()

        // then
        #expect(rig.counter.flashes == 4)
        #expect(rig.owner.isTimerActive)
    }

    @Test func givenExitedOwner_whenTickedAcrossLingerDeadline_thenFlashesUntilDeadlineThenStopsAndInvalidatesTimer() {
        // given
        let rig = makeRig()
        defer { rig.owner.detach(); rig.window.contentView = nil; rig.window.close() }
        rig.owner.pointerEntered()
        let timer = rig.owner.refreshTimer
        rig.owner.pointerExited()

        // when
        rig.clock.now += 1
        rig.owner.tick()
        let flashesBeforeDeadline = rig.counter.flashes
        rig.clock.now += 1
        rig.owner.tick()

        // then
        #expect(flashesBeforeDeadline == 2)
        #expect(rig.counter.flashes == 2)
        #expect(!rig.owner.isTimerActive)
        #expect(timer?.isValid == false)
    }

    @Test func givenHoveringOwner_whenPointerIsOutsideAtTick_thenItLingersThenStops() {
        // given
        let rig = makeRig()
        defer { rig.owner.detach(); rig.window.contentView = nil; rig.window.close() }
        rig.owner.pointerEntered()
        rig.pointer.location = NSPoint(x: 500, y: 500)

        // when
        rig.owner.tick()
        let flashesWhileLingering = rig.counter.flashes
        rig.clock.now += 2
        rig.owner.tick()

        // then
        #expect(flashesWhileLingering == 2)
        #expect(rig.counter.flashes == 2)
        #expect(!rig.owner.isTimerActive)
    }

    @Test func givenHoveringOwner_whenWindowIsNotKeyAtTick_thenItLingersThenStops() {
        // given
        let rig = makeRig()
        defer { rig.owner.detach(); rig.window.contentView = nil; rig.window.close() }
        rig.owner.pointerEntered()
        rig.pointer.windowIsKey = false

        // when
        rig.owner.tick()
        let flashesWhileLingering = rig.counter.flashes
        rig.clock.now += 2
        rig.owner.tick()

        // then
        #expect(flashesWhileLingering == 2)
        #expect(rig.counter.flashes == 2)
        #expect(!rig.owner.isTimerActive)
    }

    @Test func givenInjectedClock_whenDetachedAndReattached_thenScheduleStillUsesIt() {
        // given
        let rig = makeRig()
        defer { rig.owner.detach(); rig.window.contentView = nil; rig.window.close() }
        rig.owner.pointerEntered()
        rig.owner.detach()

        // when
        rig.owner.attach(to: rig.scroll)
        rig.owner.pointerEntered()
        rig.owner.pointerExited()
        rig.clock.now += 1
        rig.owner.tick()
        let beforeDeadline = rig.counter.flashes
        rig.clock.now += 1
        rig.owner.tick()

        // then
        #expect(beforeDeadline == 3)
        #expect(rig.counter.flashes == 3)
        #expect(!rig.owner.isTimerActive)
    }

    @Test func givenPointerOnScroller_whenTickedAfterEntry_thenEntryFlashedOnceAndLaterTicksSkip() throws {
        // given
        let rig = makeRig(withScroller: true)
        defer { rig.owner.detach(); rig.window.contentView = nil; rig.window.close() }
        let frame = try #require(rig.scroll.horizontalScroller?.frame)
        #expect(!frame.isEmpty)
        rig.pointer.location = NSPoint(x: frame.midX, y: frame.midY)

        // when
        rig.owner.pointerEntered()
        let afterEntry = rig.counter.flashes
        rig.owner.tick()
        rig.owner.tick()

        // then
        #expect(afterEntry == 1)
        #expect(rig.counter.flashes == 1)
    }

    @Test func givenLingering_whenReenteredOnScroller_thenNextTickFlashesOnceThenSkips() throws {
        // given
        let rig = makeRig(withScroller: true)
        defer { rig.owner.detach(); rig.window.contentView = nil; rig.window.close() }
        let frame = try #require(rig.scroll.horizontalScroller?.frame)
        rig.pointer.location = NSPoint(x: frame.midX, y: frame.midY)
        rig.owner.pointerEntered()
        rig.owner.pointerExited()
        rig.clock.now += 0.5
        rig.owner.tick()
        let beforeReentry = rig.counter.flashes

        // when
        rig.owner.pointerEntered()
        rig.owner.tick()
        let afterFirstTick = rig.counter.flashes
        rig.owner.tick()

        // then
        #expect(beforeReentry == 2)
        #expect(afterFirstTick == 3)
        #expect(rig.counter.flashes == 3)
    }

    private struct WeakOwner {
        weak var owner: ScrollHoverRevealOwner?
    }

    @Test func givenDetachedOwner_whenTicked_thenItNeitherFlashesNorRestartsTimer() async throws {
        // given
        _ = NSApplication.shared
        let counter = Counter()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let owner = ScrollHoverRevealOwner(flash: { _ in counter.flashes += 1 })
        owner.attach(to: scroll)
        owner.pointerEntered()
        #expect(counter.flashes == 1)
        #expect(owner.isTimerActive)

        // when
        owner.detach()
        owner.tick()
        owner.pointerEntered()

        // then
        #expect(counter.flashes == 1)
        #expect(!owner.isTimerActive)
        #expect(scroll.trackingAreas.isEmpty)
    }

    @Test func givenHostedRow_whenAttached_thenExactlyOneProbeAreaOnRowScrollAndNoneOnOuter() async throws {
        // given
        _ = NSApplication.shared
        let (host, window) = makeHost(nestedInOuterScroll: true)
        defer { window.contentView = nil; window.close() }

        // when
        await waitUntil(timeout: 5) { rowScroll(in: host).map(probeAreas) == 1 }
        let row = try #require(rowScroll(in: host))
        let outers = scrollViews(in: host).filter { $0 !== row }

        // then
        #expect(probeAreas(row) == 1)
        #expect(!outers.isEmpty)
        #expect(outers.allSatisfy { probeAreas($0) == 0 })
    }

    @Test func givenHostedRow_whenSwiftUIUpdates_thenStillExactlyOneProbeArea() async throws {
        // given
        _ = NSApplication.shared
        let (host, window) = makeHost()
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { rowScroll(in: host).map(probeAreas) == 1 }

        // when
        host.rootView = AnyView(makeRow().frame(width: 280, height: 180))
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let row = rowScroll(in: host) else { return false }
            return abs(row.frame.width - 280) < 0.5
        }

        // then
        let row = try #require(rowScroll(in: host))
        #expect(probeAreas(row) == 1)
    }

    @Test func givenHostedRow_whenTornDown_thenAreasTimerAndOwnerAreReleased() async throws {
        // given
        _ = NSApplication.shared
        let (host, window) = makeHost()
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { rowScroll(in: host).map(probeAreas) == 1 }
        let row = try #require(rowScroll(in: host))
        var weakOwner = WeakOwner()
        var timer: Timer?
        do {
            let owner = try #require(row.trackingAreas.compactMap { $0.owner as? ScrollHoverRevealOwner }.first)
            weakOwner = WeakOwner(owner: owner)
            owner.pointerEntered()
            timer = owner.refreshTimer
            #expect(owner.isTimerActive)
        }
        #expect(weakOwner.owner != nil)

        // when
        window.contentView = nil

        // then
        await waitUntil(timeout: 5) { weakOwner.owner == nil && probeAreas(row) == 0 }
        #expect(probeAreas(row) == 0)
        #expect(weakOwner.owner == nil)
        #expect(try #require(timer).isValid == false)
    }

    // MARK: Helpers

    private func makeRow() -> some View {
        WorkflowScrollRow {
            HStack(spacing: 0) {
                ForEach(0 ..< 10, id: \.self) { _ in
                    Rectangle().frame(width: 100, height: 40)
                }
            }
        }
    }

    private func makeHost(nestedInOuterScroll: Bool = false) -> (NSHostingView<AnyView>, NSWindow) {
        let root = if nestedInOuterScroll {
            AnyView(ScrollView(.vertical) { makeRow() }.frame(width: 300, height: 200))
        } else {
            AnyView(makeRow().frame(width: 300, height: 200))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (host, window)
    }

    private func probeAreas(_ scroll: NSScrollView) -> Int {
        scroll.trackingAreas.count { $0.owner is ScrollHoverRevealOwner }
    }

    private func rowScroll(in host: NSView) -> NSScrollView? {
        host.layoutSubtreeIfNeeded()
        return scrollViews(in: host).first { $0.hasHorizontalScroller && $0.documentView != nil }
    }

    private func scrollViews(in host: NSView) -> [NSScrollView] {
        descendants(host).compactMap { $0 as? NSScrollView }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
