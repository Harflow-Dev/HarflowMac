import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import QuartzCore
import SwiftUI
import Testing

// MARK: - ActivityFeedTranscriptStyleHostedTests + composer edge

extension ActivityFeedTranscriptStyleHostedTests {
    @MainActor private final class CancelRecorder {
        var messageID: String?
    }

    @Test(arguments: [false, true])
    func givenTaskDetailTranscriptWithQueuedMessage_whenMountedStandaloneOrEmbedded_thenFadeAndQueueShareTheNativeFeed(
        embedded: Bool
    ) async throws {
        // given
        let mounted = try await composerEdgeMount(embedded: embedded, dark: false,
                                                  size: CGSize(width: 1000, height: 620))
        let fixture = mounted.fixture
        defer { fixture.close() }
        let host = fixture.host
        let table = try #require(Self.tables(host).first)
        let scroll = try #require(table.enclosingScrollView)
        let document = try #require(scroll.documentView)
        let documentHeight = document.bounds.height
        let edge = try #require(scroll.subviews.first { $0.layer is CAGradientLayer })
        assertEdgeFrame(edge, in: scroll)

        // when — overflow exposes the fade; reaching the end hides it without changing document height.
        let initialOffset = scroll.documentVisibleRect.minY
        activityNativeTestScroll(scroll, to: max(0, initialOffset - 300))
        await fixture.settle {
            !edge.isHidden && document.bounds.height > scroll.contentView.bounds.height
                && document.bounds.maxY - scroll.documentVisibleRect.maxY > 200
        }
        #expect(!edge.isHidden, "the composer fade is visible while transcript content overflows")
        let bottomIndex = try #require(table.owner?.entries.lastIndex { $0.id == "activity-feed-bottom" })
        let tailIndex = try #require(table.owner?.entries.lastIndex { $0.id == "activity-feed-tail" })
        #expect(tailIndex < bottomIndex)
        let endY = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: endY))
        scroll.reflectScrolledClipView(scroll.contentView)
        await fixture.settle {
            let gap = document.bounds.maxY - scroll.documentVisibleRect.maxY
            return gap <= 1 && edge.isHidden
        }

        // then — the queued bubble and its action stay in this feed's document and remain reachable.
        #expect(edge.isHidden, "the fade is hidden at the transcript end")
        #expect(abs(document.bounds.height - documentHeight) < 1, "the fade does not add document height")
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        await fixture.settle { fixture.element("Cancel queued message") != nil }
        let cancel = try #require(fixture.element("Cancel queued message"))
        let cancelFrame = try #require(fixture.frame(cancel))
        let cancelInDocument = document.convert(cancelFrame, from: nil)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        #expect(document.bounds.contains(cancelInDocument), "Cancel is inside the activity document")
        #expect(viewport.contains(cancelFrame), "Cancel is reachable inside the visible feed viewport")
        #expect(scroll.documentView === table, "the composer and queue use the same native feed document")
        #expect(fixture.press(cancel), "the queued message Cancel action is reachable")
        #expect(mounted.cancelRecorder.messageID == "composer-edge-queued")
    }

    @Test(arguments: [false, true])
    func givenTaskDetailComposerCapture_whenCaptureDirectorySet_thenStandaloneAndEmbeddedAppearancesAreRecorded(dark: Bool) async throws {
        guard let directory = HostedCaptureEvidence.directory("HARFLOW_STAGE3_COMPOSER_CAPTURE_DIR") else { return }
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for embedded in [false, true] {
            for size in [CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 620)] {
                let mounted = try await composerEdgeMount(embedded: embedded, dark: dark, size: size)
                let fixture = mounted.fixture
                defer { fixture.close() }
                await HostedCaptureEvidence.prepare(fixture.window, dark: dark)
                let table = try #require(Self.tables(fixture.host).first)
                let scroll = try #require(table.enclosingScrollView)
                let document = try #require(scroll.documentView)
                let edge = try #require(scroll.subviews.first { $0.layer is CAGradientLayer })
                assertEdgeFrame(edge, in: scroll)
                activityNativeTestScroll(scroll, to: max(0, scroll.documentVisibleRect.minY - 300))
                await fixture.settle { !edge.isHidden && document.bounds.maxY - scroll.documentVisibleRect.maxY > 200 }
                #expect(!edge.isHidden && document.bounds.maxY - scroll.documentVisibleRect.maxY > 200,
                        "The overflow capture shows the fade above the transcript end")
                await DisplayFrames.waitForPresentedFrame()
                let surface = embedded ? "embedded" : "standalone"
                let sizeInPoints = NSSize(width: size.width, height: size.height)
                let overflowRoute = embedded ? "task/composer-edge-embedded"
                    : (size.width <= 1000 ? "task/composer-edge-minimum" : "task/composer-edge")
                let endRoute = embedded ? "task/composer-edge-embedded" : "task/composer-edge-end"
                let design = HostedCaptureEvidence.Design(route: overflowRoute,
                                                          file: "v2/scripts/states-composer-edge.js",
                                                          commit: "f345556ae3f36c6ba3ded013f272fc096c83d585")
                let overflow = HostedCaptureEvidence.Subject(suite: "task-detail-composer-edge",
                                                             state: "\(surface)-overflow", dark: dark,
                                                             size: sizeInPoints, design: design)
                try await HostedCaptureEvidence.record(directory: directory, subject: overflow,
                                                       window: fixture.window, host: fixture.host)
                let endY = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
                scroll.contentView.scroll(to: NSPoint(x: 0, y: endY))
                scroll.reflectScrolledClipView(scroll.contentView)
                await fixture.settle { edge.isHidden && document.bounds.maxY - scroll.documentVisibleRect.maxY <= 1 }
                await DisplayFrames.waitForPresentedFrame()
                #expect(edge.isHidden && document.bounds.maxY - scroll.documentVisibleRect.maxY <= 1,
                        "The end capture has no composer fade")
                let endDesign = HostedCaptureEvidence.Design(route: endRoute, file: design.file, commit: design.commit)
                let end = HostedCaptureEvidence.Subject(suite: "task-detail-composer-edge", state: "\(surface)-end",
                                                       dark: dark, size: sizeInPoints, design: endDesign)
                try await HostedCaptureEvidence.record(directory: directory, subject: end,
                                                       window: fixture.window, host: fixture.host)
            }
        }
    }

    private func composerEdgeMount(embedded: Bool, dark: Bool, size: CGSize) async throws -> (fixture: RedesignHost, cancelRecorder: CancelRecorder) {
        _ = NSApplication.shared
        let mock = PaneMocks.running()
        var model = Self.timelineModel((0 ..< 24).map { index in
            ActivityFixture.text(index, "Transcript line \(index): the content remains in the same native scroll document.",
                                 task: Self.taskID)
        })
        model.workMessages = [WorkMessageBubble(id: "composer-edge-queued", seq: 25,
                                                kind: .queued(canCancel: true, note: nil), text: "Queued follow-up")]
        let cancelRecorder = CancelRecorder()
        model.onCancelQueuedMessage = { cancelRecorder.messageID = $0 }
        mock.timelineModel = model
        let root = NavigationStack {
            TaskDetailView(mock, chrome: embedded ? .embedded : .standalone,
                           transcriptStyle: embedded ? .standard : .transcript)
        }
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.hfReduceMotionOverride, true)
        let fixture = RedesignHost(root, size: size)
        await fixture.settle {
            guard let table = Self.tables(fixture.host).first,
                  let scroll = table.enclosingScrollView else { return false }
            return table.owner?.model != nil && (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height
        }
        return (fixture, cancelRecorder)
    }

    private func assertEdgeFrame(_ edge: NSView, in scroll: NSScrollView) {
        let clipFrame = scroll.convert(scroll.contentView.bounds, from: scroll.contentView)
        #expect(abs(edge.frame.minX - clipFrame.minX) < 1)
        #expect(abs(edge.frame.width - clipFrame.width) < 1)
        #expect(abs(edge.frame.height - min(16, clipFrame.height)) < 1)
        let expectedBottom = scroll.isFlipped ? clipFrame.maxY : clipFrame.minY + edge.frame.height
        #expect(abs(edge.frame.maxY - expectedBottom) < 1, "The fade follows the clipped viewport edge")
    }
}
