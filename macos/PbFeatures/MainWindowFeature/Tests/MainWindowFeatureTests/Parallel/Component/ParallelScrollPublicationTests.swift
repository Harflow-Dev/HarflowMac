import AppKit
@testable import MainWindowFeature
import PbTestUtilities
import Testing

// MARK: - ParallelScrollPublicationTests

@MainActor @Suite(.serialized) struct ParallelScrollPublicationTests {
    @Test func givenZeroViewport_whenRestorationWaitsForReadyGeometry_thenNoPrematureAcknowledgementIsPublished() async throws {
        // given
        let (window, scroll, observer, position) = zeroViewportFixture()
        defer { window.contentView = nil; window.close() }
        await waitUntil { @MainActor in position.reports > 0 }
        let before = position.reports
        // when — request while the clip view has no height, then let it become ready.
        observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: true)
        await drainMainQueue()
        #expect(position.reports == before)
        scroll.frame.size.height = 300
        await waitUntil { @MainActor in abs(position.offset - 120) < 1 }
        // then
        #expect(abs(position.offset - 120) < 1)
        #expect(position.reports > before)
        let readyReports = position.reports
        observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: true)
        await drainMainQueue()
        #expect(position.reports == readyReports)
    }

    @Test func givenPendingRestoration_whenDeactivatedBeforeViewportIsReady_thenUnchangedReportDoesNotAcknowledgeIt() async throws {
        // given
        let (window, _, observer, position) = zeroViewportFixture()
        defer { window.contentView = nil; window.close() }
        await waitUntil { @MainActor in position.reports > 0 }
        let before = position.reports
        // when
        observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: true)
        observer.configure(ids: [], stride: 0, restorationOffset: nil, restorationActive: false)
        await drainMainQueue()
        // then — cancelling the request also cancels its deferred acknowledgement.
        #expect(position.reports == before)
        #expect(position.offset == 0)
    }

    @Test func givenActiveRestoration_whenUnchangedConfigurationRepeats_thenPositionReportsStayQuiet() async throws {
        // given — exercise the native observer without SwiftUI or lazy height estimates.
        _ = NSApplication.shared
        let position = Position()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 400, height: 1000))
        let observer = ParallelScrollObservationView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        observer.axis = .vertical
        observer.onPosition = { offset, _, _ in position.offset = offset; position.reports += 1 }
        document.addSubview(observer)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: true)
        await waitUntil { @MainActor in abs(position.offset - 120) < 1 }
        let initialReports = position.reports
        #expect(initialReports > 0)
        // when — the representable updates callbacks while its requested restoration is unchanged.
        for _ in 0 ..< 10 {
            observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: true)
        }
        await drainMainQueue()
        // then — reconfiguration is quiet, but an actual changed target still restores and reports.
        #expect(position.reports == initialReports)
        observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: false)
        await drainMainQueue()
        #expect(position.reports == initialReports)
        observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: true)
        await drainMainQueue()
        #expect(position.reports == initialReports + 1, "A newly active request at its target is acknowledged once")
        observer.configure(ids: [], stride: 0, restorationOffset: 120, restorationActive: true)
        await drainMainQueue()
        #expect(position.reports == initialReports + 1)
        observer.configure(ids: [], stride: 0, restorationOffset: 240, restorationActive: true)
        await waitUntil { @MainActor in abs(position.offset - 240) < 1 }
        #expect(abs(position.offset - 240) < 1)
        #expect(position.reports > initialReports)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func zeroViewportFixture() -> (NSWindow, NSScrollView, ParallelScrollObservationView, Position) {
        _ = NSApplication.shared
        let position = Position()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 0))
        let document = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 400, height: 1000))
        let observer = ParallelScrollObservationView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        observer.axis = .vertical
        observer.onPosition = { offset, _, _ in position.offset = offset; position.reports += 1 }
        document.addSubview(observer)
        scroll.documentView = document
        container.addSubview(scroll)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.orderFront(nil)
        return (window, scroll, observer, position)
    }

    private final class Position {
        var offset: CGFloat = 0
        var reports = 0
    }

    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }
}
