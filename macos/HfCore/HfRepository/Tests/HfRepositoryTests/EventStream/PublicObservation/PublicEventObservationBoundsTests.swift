import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PublicEventObservationBoundsTests

@Suite struct PublicEventObservationBoundsTests {
    @Test func givenFullActivityCapacity_whenOlderPageExceedsRemainingSpace_thenEntirePageAndCursorAreRetained() async {
        // given
        let reader = ObservationScriptReader()
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        // Unknown semantics stop summary work while retaining every raw record for activity.
        let initial = (0 ..< 200).map { ObservationFixtures.record($0, "future_kind") }
        reader.finish(0, .success(ObservationFixtures.page(initial, older: "older-0", capture: "future_capture")))
        await waitUntil { sut.snapshot.activity.count == 200 }
        for index in 1 ... 9 {
            sut.requestOlder()
            await waitUntil { reader.requests.count > index }
            let records = (0 ..< 200).map { ObservationFixtures.record(index * 200 + $0, "future_kind") }
            reader.finish(index, .success(ObservationFixtures.page(records, older: "older-\(index)")))
            await waitUntil { sut.snapshot.activity.count == (index + 1) * 200 }
        }
        let retained = sut.snapshot.activity
        let cursor = sut.snapshot.olderCursor
        // when
        sut.requestOlder()
        await waitUntil { reader.requests.count == 11 }
        reader.finish(10, .success(ObservationFixtures.page([ObservationFixtures.record(9999)], older: "must-not-advance")))
        await waitUntil { sut.snapshot.issues.contains(.capacity) }
        // then
        #expect(sut.snapshot.activity == retained)
        #expect(sut.snapshot.olderCursor == cursor)
        #expect(sut.snapshot.activity.count == 2000)
    }

    @Test func givenRawBytesNearCapacity_whenWholePageWouldOverflow_thenBytesRecordsAndCursorStayAtLastAdmission() async {
        // given
        let reader = ObservationScriptReader()
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        let text = String(repeating: "x", count: 15000)
        let initial = (0 ..< 200).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        reader.finish(0, .success(ObservationFixtures.page(initial, older: "retained", capture: "future_capture")))
        await waitUntil { sut.snapshot.activity.count == 200 }
        let retained = sut.snapshot
        // when
        sut.requestOlder()
        await waitUntil { reader.requests.count == 2 }
        let next = (200 ..< 300).map { ObservationFixtures.record($0, "notice", ["text": .string(text)]) }
        reader.finish(1, .success(ObservationFixtures.page(next, older: "rejected")))
        await waitUntil { sut.snapshot.issues.contains(.capacity) }
        // then
        #expect(sut.snapshot.rawBytes == retained.rawBytes)
        #expect(sut.snapshot.activity == retained.activity)
        #expect(sut.snapshot.olderCursor == "retained")
        #expect(sut.snapshot.rawBytes <= 4 * 1024 * 1024)
    }

    @Test func givenForwardNonprogress_whenMoreIsTrueWithSameCursor_thenImmediateDrainStopsWithTypedIssue() async {
        // given
        let reader = ObservationScriptReader()
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        await waitUntil { reader.requests.count == 1 }
        // An unknown payload isolates live lane behavior from chronological summary recovery.
        reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1, "future_kind")], newer: "same", more: true)))
        await waitUntil { reader.requests.count == 2 }
        // when
        reader.finish(1, .success(ObservationFixtures.page(newer: "same", more: true)))
        await waitUntil { sut.snapshot.issues.contains(.nonprogress) }
        // then
        #expect(sut.snapshot.liveCursor == "same")
        #expect(!sut.snapshot.forwardDrained)
        #expect(sut.snapshot.activity.count == 1)
        #expect(reader.requests.count == 2)
    }
}
