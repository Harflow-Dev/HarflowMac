import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing
@preconcurrency import UserNotifications

@Suite struct FinishNotifierImplTests {

    @Test func givenABareSwiftRunBinary_whenNotifying_thenNothingIsSent() async {
        // given — F4-25: no `.app` bundle, no bundle id.
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = MockNotificationCentering()
        given(center).requestAuthorization(options: .any).willReturn(true)
        let sut = FinishNotifierImpl(settings: settings, center: center, bundleIdentifier: { nil }, isAppBundle: { false })

        // when
        sut.notify([makeTaskInfo("t1", status: "completed")]) { _ in "Task" }
        try? await Task.sleep(for: .milliseconds(50))

        // then
        verify(center).requestAuthorization(options: .any).called(0)
    }

    @Test func givenNotifyOnFinishIsOff_whenNotifying_thenNothingIsSent() async {
        // given
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.setNotifyOnFinish(false)
        let center = MockNotificationCentering()
        given(center).requestAuthorization(options: .any).willReturn(true)
        let sut = FinishNotifierImpl(settings: settings, center: center, bundleIdentifier: { "dev.polybridge.monitor" }, isAppBundle: { true })

        // when
        sut.notify([makeTaskInfo("t1")]) { _ in "Task" }
        try? await Task.sleep(for: .milliseconds(50))

        // then
        verify(center).requestAuthorization(options: .any).called(0)
    }

    @Test func givenNoFinishedTasks_whenNotifying_thenNothingIsSent() async {
        // given
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = MockNotificationCentering()
        given(center).requestAuthorization(options: .any).willReturn(true)
        let sut = FinishNotifierImpl(settings: settings, center: center, bundleIdentifier: { "dev.polybridge.monitor" }, isAppBundle: { true })

        // when
        sut.notify([]) { _ in "Task" }
        try? await Task.sleep(for: .milliseconds(50))

        // then
        verify(center).requestAuthorization(options: .any).called(0)
    }

    @Test func givenAFinishedRoot_whenNotified_thenTheIdentifierTitleBodyAndUserInfoMatch() async {
        // given — F4-25's exact copy: identifier `finished-<id>`, title "<status.label>: <title>",
        // body "<backend> · <repo>", userInfo carries task_id.
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let center = MockNotificationCentering()
        given(center).requestAuthorization(options: .any).willReturn(true)
        let addedRequests = LockedBox<[UNNotificationRequest]>([])
        given(center).add(.any).willProduce { request in addedRequests.mutate { $0.append(request) } }
        let sut = FinishNotifierImpl(settings: settings, center: center, bundleIdentifier: { "dev.polybridge.monitor" }, isAppBundle: { true })
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let task = makeTaskInfo("abc12345", status: "completed", backend: "claude", repoPath: home + "/repo")

        // when
        sut.notify([task]) { _ in "My Task" }
        await waitUntil { !addedRequests.value.isEmpty }

        // then
        let request = addedRequests.value[0]
        #expect(request.identifier == "finished-abc12345")
        #expect(request.content.title == "Done: My Task")
        #expect(request.content.body == "claude · ~/repo")
        #expect(request.content.userInfo["task_id"] as? String == "abc12345")
    }
}
