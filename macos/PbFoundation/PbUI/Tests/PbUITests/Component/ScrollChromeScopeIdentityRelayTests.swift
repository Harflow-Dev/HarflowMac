import AppKit
import PbTestUtilities
@testable import PbUI
import Testing

// MARK: - ScrollChromeScopeIdentityRelayTests

@MainActor @Suite(.serialized) struct ScrollChromeScopeIdentityRelayTests {
    @Test func givenTwoMarkersReportingTheSameScrollView_whenReportsCoalesce_thenIdentityPublishesOnce() async throws {
        // given
        let relay = ScrollChromeScopeIdentityRelay()
        let first = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let second = ScrollChromeScopeMarkerView(pairID: first.pairID)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var delivered: [ObjectIdentifier?] = []
        relay.install { delivered.append($0.map(ObjectIdentifier.init)) }

        // when — both marker halves discover the same native owner in one main-queue burst.
        relay.report(scroll, from: first)
        relay.report(scroll, from: second)
        await waitUntil(timeout: 2) { delivered.count == 1 }

        // then
        #expect(delivered == [ObjectIdentifier(scroll)])
    }

    @Test func givenSameScrollReplacesDocument_whenReportsAreDelivered_thenBothDocumentIdentitiesPublish() async throws {
        // given — the marker pair continues to disclose one native scroll view while SwiftUI
        // replaces its document view.
        let relay = ScrollChromeScopeIdentityRelay()
        let marker = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let documentA = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let documentB = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
        scroll.documentView = documentA
        var deliveredDocuments: [ObjectIdentifier?] = []
        relay.install { deliveredDocuments.append($0?.documentView.map(ObjectIdentifier.init)) }
        relay.report(scroll, from: marker)
        await waitUntil(timeout: 2) { deliveredDocuments.count == 1 }

        // when — B replaces A on the same native owner.
        scroll.documentView = documentB
        relay.report(scroll, from: marker)
        await waitUntil(timeout: 2) { deliveredDocuments.count == 2 }

        // then — document identity participates in deduplication even though scroll identity is
        // unchanged.
        #expect(deliveredDocuments == [ObjectIdentifier(documentA), ObjectIdentifier(documentB)])
    }

    @Test func givenSameScrollDocumentTemporarilyBecomesNil_whenReplacementReturns_thenNilGapPublishesOnce() async throws {
        // given — A is live and the relay has already published the pair.
        let relay = ScrollChromeScopeIdentityRelay()
        let marker = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let documentA = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let documentB = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
        scroll.documentView = documentA
        var deliveredDocuments: [ObjectIdentifier?] = []
        relay.install { deliveredDocuments.append($0?.documentView.map(ObjectIdentifier.init)) }
        relay.report(scroll, from: marker)
        await waitUntil(timeout: 2) { deliveredDocuments.count == 1 }

        // when — the same native owner briefly has no document, then receives B.
        scroll.documentView = nil
        relay.report(scroll, from: marker)
        await waitUntil(timeout: 2) { deliveredDocuments.count == 2 }
        scroll.documentView = documentB
        relay.report(scroll, from: marker)
        await waitUntil(timeout: 2) { deliveredDocuments.count == 3 }

        // then — the transition is visible once, and the replacement is visible once.
        #expect(deliveredDocuments == [ObjectIdentifier(documentA), nil, ObjectIdentifier(documentB)])
    }

    @Test func givenDeliveredDocumentIsReleased_whenSameScrollReceivesReplacement_thenRelayDoesNotRetainTheOldDocument() async throws {
        // given — the relay has delivered A, but only the scroll view owns it.
        let relay = ScrollChromeScopeIdentityRelay()
        let marker = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        weak var retiredDocument: NSView?
        var retiredDocumentID: ObjectIdentifier?
        var deliveredDocuments: [ObjectIdentifier?] = []
        relay.install { deliveredDocuments.append($0?.documentView.map(ObjectIdentifier.init)) }
        autoreleasepool {
            let documentA = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
            retiredDocument = documentA
            retiredDocumentID = ObjectIdentifier(documentA)
            scroll.documentView = documentA
            relay.report(scroll, from: marker)
        }
        await waitUntil(timeout: 2) { deliveredDocuments.count == 1 }

        // when — removing A releases the only strong document owner before the relay is told
        // about the nil gap. AppKit may defer destruction, so drain a bounded main-queue window.
        scroll.documentView = nil
        await waitUntil(timeout: 2) { retiredDocument == nil }
        try #require(retiredDocument == nil, "The test document must be released before weak-zeroing delivery")
        relay.report(scroll, from: marker)
        await waitUntil(timeout: 2) { deliveredDocuments.count == 2 }

        let documentB = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
        scroll.documentView = documentB
        relay.report(scroll, from: marker)
        await waitUntil(timeout: 2) { deliveredDocuments.count == 3 }

        // then — the relay reports the nil gap and B, and never kept A alive.
        #expect(deliveredDocuments == [retiredDocumentID, nil, ObjectIdentifier(documentB)])
    }

    @Test func givenOneMarkerChurns_whenItsPeerStillOwnsTheScroll_thenIdentitySurvivesUntilBothDetach() async throws {
        // given
        let relay = ScrollChromeScopeIdentityRelay()
        let first = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let second = ScrollChromeScopeMarkerView(pairID: first.pairID)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var delivered: [ObjectIdentifier?] = []
        relay.install { delivered.append($0.map(ObjectIdentifier.init)) }
        relay.report(scroll, from: first)
        relay.report(scroll, from: second)
        await waitUntil(timeout: 2) { delivered.count == 1 }

        // when — one marker is replaced, then the surviving marker is replaced too.
        relay.report(nil, from: first)
        await Task.yield()
        #expect(delivered == [ObjectIdentifier(scroll)])
        relay.report(nil, from: second)
        await waitUntil(timeout: 2) { delivered.count == 2 }

        // then
        #expect(delivered == [ObjectIdentifier(scroll), nil])
    }

    @Test func givenReportsArriveDuringLayout_whenDeferredDeliveryRuns_thenOnlyNewestIdentityPublishesAfterLayout() async throws {
        // given
        let relay = ScrollChromeScopeIdentityRelay()
        let marker = ScrollChromeScopeMarkerView(pairID: ScrollChromeScopePairID())
        let first = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let second = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var inLayout = true
        var callbackDuringLayout = false
        var delivered: [ObjectIdentifier?] = []
        relay.install {
            callbackDuringLayout = inLayout
            delivered.append($0.map(ObjectIdentifier.init))
        }

        // when — stale A and current B are reported before the deferred hop runs.
        relay.report(first, from: marker)
        relay.report(second, from: marker)
        #expect(delivered.isEmpty)
        inLayout = false
        await waitUntil(timeout: 2) { delivered.count == 1 }

        // then
        #expect(!callbackDuringLayout)
        #expect(delivered == [ObjectIdentifier(second)])
    }

}
