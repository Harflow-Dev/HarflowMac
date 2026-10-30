import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing
@preconcurrency import UserNotifications

// MARK: - NeedsYouNotifierImplTests

@Suite struct NeedsYouNotifierImplTests {
    private struct Rig: @unchecked Sendable {
        let sut: NeedsYouNotifierImpl
        let events: PassthroughSubject<NeedsYouEvent, Never>
        let center: MockNotificationCentering
        let scheduler: CapturingScheduler
        let added: LockedBox<[UNNotificationRequest]>
        let removed: LockedBox<[String]>
        let settings: SettingsRepositoryImpl
    }

    private func rig(notify: Bool = true, app: Bool = true) -> Rig {
        let events = PassthroughSubject<NeedsYouEvent, Never>()
        let repository = MockNeedsYouRepository()
        given(repository).eventsPublisher().willReturn(events.eraseToAnyPublisher())
        let center = MockNotificationCentering()
        given(center).requestAuthorization(options: .any).willReturn(true)
        let added = LockedBox<[UNNotificationRequest]>([])
        let removed = LockedBox<[String]>([])
        given(center).registerCategory(.any).willReturn()
        given(center).add(.any).willProduce { request in added.mutate { $0.append(request) } }
        given(center).removeDeliveredNotifications(withIdentifiers: .any).willProduce { ids in removed.mutate { $0 += ids } }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.setNotifyOnNeedsYou(notify)
        let scheduler = CapturingScheduler()
        let sut = NeedsYouNotifierImpl(repository: repository, settings: settings, center: center, scheduler: scheduler,
                                       bundleIdentifier: { app ? "dev.harflow.mac" : nil }, isAppBundle: { app })
        sut.start()
        return Rig(sut: sut, events: events, center: center, scheduler: scheduler, added: added, removed: removed, settings: settings)
    }

    private func item(_ id: String, ended: Bool = false, kind: NeedsYouItem.Kind = .question) -> NeedsYouItem {
        let ownership = NeedsYouItem.Ownership(owner: "monitor", callerEnded: ended, engineNote: "", handover: nil)
        return NeedsYouItem(id: id, kind: kind, runTitle: "Release", text: "First line\nSecond", ownership: ownership,
                     startedBy: "Mac app")
    }

    @Test func givenBaselineItem_whenAppeared_thenNothingIsNotified() async {
        // given
        let rig = rig()
        // when
        rig.events.send(.appeared(item("input:a:1"), sourceBaseline: true))
        rig.scheduler.fireFirstOneShot()
        // then
        #expect(rig.scheduler.oneShots.isEmpty)
        #expect(rig.added.value.isEmpty)
    }

    @Test func givenNewItem_whenFlushed_thenIdentifierTitleSubtitleBodyAndUserInfoMatch() async {
        // given
        let rig = rig()
        // when
        rig.events.send(.appeared(item("input:a:1", ended: true), sourceBaseline: false))
        rig.scheduler.fireFirstOneShot()
        await waitUntil { rig.added.value.count == 1 }
        // then
        let request = rig.added.value.first
        #expect(request?.identifier == "needs-you-input:a:1")
        #expect(request?.content.title == "Question: Release")
        #expect(request?.content.subtitle == "The caller ended. You can answer now.")
        #expect(request?.content.body == "First line")
        #expect(request?.content.threadIdentifier == "needs-you")
        #expect(request?.content.userInfo["needs_you_item"] as? String == "input:a:1")
    }

    @Test func givenMoreThanThreeItems_whenFlushed_thenOneSummaryIsPostedAndRemovedWhenAllResolve() async {
        // given
        let rig = rig()
        let ids = (1 ... 4).map { "input:a:\($0)" }
        // when
        for id in ids { rig.events.send(.appeared(item(id), sourceBaseline: false)) }
        rig.scheduler.fireFirstOneShot()
        await waitUntil { rig.added.value.count == 1 }
        for id in ids.dropLast() { rig.events.send(.resolved(id)) }
        let beforeLast = rig.removed.value.contains("needs-you-summary")
        rig.events.send(.resolved(ids[3]))
        // then
        #expect(rig.added.value.first?.identifier == "needs-you-summary")
        #expect(rig.added.value.first?.content.title == "4 requests need you")
        #expect(rig.added.value.first?.content.userInfo["needs_you_list"] as? String == "1")
        #expect(!beforeLast && rig.removed.value.contains("needs-you-summary"))
    }

    @Test func givenResolvedItem_whenEventArrives_thenDeliveredNotificationIsRemoved() {
        // given
        let rig = rig()
        // when
        rig.events.send(.resolved("input:a:1"))
        // then
        #expect(rig.removed.value == ["needs-you-input:a:1"])
    }

    @Test func givenItemResolvedBeforeFlush_whenFlushed_thenItIsNotNotified() {
        // given
        let rig = rig()
        rig.events.send(.appeared(item("input:a:1"), sourceBaseline: false))
        // when
        rig.events.send(.resolved("input:a:1"))
        rig.scheduler.fireFirstOneShot()
        // then
        #expect(rig.added.value.isEmpty)
    }

    @Test func givenSettingOff_whenFlushed_thenNothingIsNotified() {
        // given
        let rig = rig(notify: false)
        // when
        rig.events.send(.appeared(item("input:a:1"), sourceBaseline: false))
        rig.scheduler.fireFirstOneShot()
        // then
        #expect(rig.added.value.isEmpty)
    }

    @Test func givenBareBinary_whenFlushed_thenNothingIsNotified() {
        // given
        let rig = rig(app: false)
        // when
        rig.events.send(.appeared(item("input:a:1"), sourceBaseline: false))
        rig.scheduler.fireFirstOneShot()
        // then
        #expect(rig.added.value.isEmpty)
    }

    @Test func givenApprovalWithCommand_whenFlushed_thenBodyNamesOnlyTheToolAndHidesPreviews() async {
        // given
        let rig = rig()
        var approvalItem = item("approval:t1:r1", kind: .approval)
        approvalItem.text = "Bash: rm -rf /secret/path"
        approvalItem.approval = approval(command: "rm -rf /secret/path")
        // when
        rig.events.send(.appeared(approvalItem, sourceBaseline: false))
        rig.scheduler.fireFirstOneShot()
        await waitUntil { rig.added.value.count == 1 }
        // then
        let content = rig.added.value.first?.content
        #expect(content?.body == "Bash approval requested")
        #expect(content?.categoryIdentifier == "needs-you")
        verify(rig.center).registerCategory(.matching { $0.hiddenPreviewsBodyPlaceholder == "A request needs you" }).called(1)
        let everything = [content?.title, content?.subtitle, content?.body].compactMap(\.self).joined(separator: " ")
        #expect(!everything.contains("secret") && !everything.contains("rm -rf"))
    }
}
