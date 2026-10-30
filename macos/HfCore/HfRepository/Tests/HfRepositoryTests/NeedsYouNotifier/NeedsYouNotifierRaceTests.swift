import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing
@preconcurrency import UserNotifications

// MARK: - GatedCenter

/// A notification center whose authorization, category registration and post can each be held open.
final class GatedCenter: NotificationCentering, @unchecked Sendable {
    enum Gate { case authorization, category, add }

    private let lock = NSLock()
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var reached: Set<String> = []
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removed: [String] = []

    func hold(_ gate: Gate) { lock.withLock { _ = held.insert("\(gate)") } }

    func release(_ gate: Gate) {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held.remove("\(gate)")
            return waiters.removeValue(forKey: "\(gate)") ?? []
        }
        toResume.forEach { $0.resume() }
    }

    func hasReached(_ gate: Gate) -> Bool { lock.withLock { reached.contains("\(gate)") } }

    private func pass(_ gate: Gate) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                reached.insert("\(gate)")
                guard held.contains("\(gate)") else { return false }
                waiters["\(gate)", default: []].append(continuation)
                return true
            }
            if !wait { continuation.resume() }
        }
    }

    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
        await pass(.authorization)
        return true
    }

    func add(_ request: UNNotificationRequest) async throws {
        await pass(.add)
        lock.withLock { added.append(request) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        lock.withLock {
            removed += identifiers
            added.removeAll { identifiers.contains($0.identifier) }
        }
    }

    func registerCategory(_: UNNotificationCategory) async { await pass(.category) }

    var delivered: [String] { lock.withLock { added.map(\.identifier) } }
}

// MARK: - NeedsYouNotifierRaceTests

@Suite struct NeedsYouNotifierRaceTests {
    private struct Rig: @unchecked Sendable {
        let sut: NeedsYouNotifierImpl
        let events: PassthroughSubject<NeedsYouEvent, Never>
        let center: GatedCenter
        let scheduler: CapturingScheduler
    }

    private func rig() -> Rig {
        let events = PassthroughSubject<NeedsYouEvent, Never>()
        let repository = MockNeedsYouRepository()
        given(repository).eventsPublisher().willReturn(events.eraseToAnyPublisher())
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = GatedCenter()
        let scheduler = CapturingScheduler()
        let sut = NeedsYouNotifierImpl(repository: repository, settings: settings, center: center, scheduler: scheduler,
                                       bundleIdentifier: { "dev.harflow.mac" }, isAppBundle: { true })
        sut.start()
        return Rig(sut: sut, events: events, center: center, scheduler: scheduler)
    }

    private func item(_ id: String) -> NeedsYouItem {
        NeedsYouItem(id: id, kind: .question, runTitle: "Run", text: "t",
                     ownership: .init(owner: "caller", callerEnded: true, engineNote: "", handover: nil), startedBy: "Original caller")
    }

    @Test(arguments: [GatedCenter.Gate.authorization, .category])
    func givenResolutionDuringAuthorizationOrCategory_whenDelivering_thenTheResolvedItemIsNeverPosted(gate: GatedCenter.Gate) async {
        // given
        let rig = rig()
        rig.center.hold(gate)
        rig.events.send(.appeared(item("input:a:1"), sourceBaseline: false))
        rig.events.send(.appeared(item("input:a:2"), sourceBaseline: false))
        rig.scheduler.fireFirstOneShot()
        await waitUntil { rig.center.hasReached(gate) }
        // when
        rig.events.send(.resolved("input:a:1"))
        rig.center.release(gate)
        await waitUntil { rig.center.delivered.contains("needs-you-input:a:2") }
        // then
        #expect(rig.center.delivered == ["needs-you-input:a:2"])
    }

    @Test func givenResolutionDuringThePost_whenDelivering_thenTheNotificationIsRemovedAfterwards() async {
        // given
        let rig = rig()
        rig.center.hold(.add)
        rig.events.send(.appeared(item("input:a:1"), sourceBaseline: false))
        rig.scheduler.fireFirstOneShot()
        await waitUntil { rig.center.hasReached(.add) }
        // when
        rig.events.send(.resolved("input:a:1"))
        rig.center.release(.add)
        await waitUntil { rig.center.removed.contains("needs-you-input:a:1") && rig.center.delivered.isEmpty }
        // then
        #expect(rig.center.delivered.isEmpty)
    }

    @Test func givenEverySummaryMemberResolvedDuringAuthorization_whenDelivering_thenNoSummaryRemains() async {
        // given
        let rig = rig()
        let ids = (1 ... 4).map { "input:a:\($0)" }
        rig.center.hold(.authorization)
        for id in ids { rig.events.send(.appeared(item(id), sourceBaseline: false)) }
        rig.scheduler.fireFirstOneShot()
        await waitUntil { rig.center.hasReached(.authorization) }
        // when
        for id in ids { rig.events.send(.resolved(id)) }
        rig.center.release(.authorization)
        await waitUntil { rig.center.removed.contains("needs-you-input:a:4") }
        // then
        #expect(rig.center.delivered.isEmpty)
    }

    @Test func givenAMemberResolvedDuringTheSummaryPost_whenAllResolve_thenTheSummaryIsCleared() async {
        // given
        let rig = rig()
        let ids = (1 ... 4).map { "input:a:\($0)" }
        rig.center.hold(.add)
        for id in ids { rig.events.send(.appeared(item(id), sourceBaseline: false)) }
        rig.scheduler.fireFirstOneShot()
        await waitUntil { rig.center.hasReached(.add) }
        // when
        for id in ids { rig.events.send(.resolved(id)) }
        rig.center.release(.add)
        await waitUntil { rig.center.removed.contains("needs-you-summary") }
        // then
        #expect(!rig.center.delivered.contains("needs-you-summary"))
    }
}
