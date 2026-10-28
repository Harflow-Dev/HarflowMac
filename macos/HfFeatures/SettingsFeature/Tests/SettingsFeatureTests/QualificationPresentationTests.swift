import Foundation
import HfRepository
import HfTestUtilities
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
struct QualificationPresentationTests {
    private actor Gate {
        private var entered = false
        private var entry: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            entry?.resume(); entry = nil
            await withCheckedContinuation { release = $0 }
        }

        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entry = $0 }
        }

        func open() { release?.resume(); release = nil }
    }

    private final class Suspended: QualificationRepository, @unchecked Sendable {
        let base: QualificationFixture
        let gate: Gate
        init(base: QualificationFixture, gate: Gate) { self.base = base; self.gate = gate }
        func runtimeToken() throws -> QualificationRuntimeToken { try base.runtimeToken() }
        func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan {
            try await base.discover(request, runtime: runtime)
        }

        func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws {
            await gate.wait()
            try await base.check(backend: backend, features: features, runtime: runtime)
        }
    }

    @Test func givenSuspendedProviderCheck_whenUICancels_thenLateSuccessCannotEnableLaunch() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let gate = Gate()
        let controller = QualificationPresentation(session: QualificationSession(repository: Suspended(base: fixture, gate: gate)))
        _ = await controller.discover(.task(options: ["--backend=fixture"]))
        let attempt = controller.check()
        await gate.waitForEntry()
        // when
        controller.cancel()
        await waitUntil { controller.cards.first?.model.state == .cancelled }
        fixture.setReady(true)
        await gate.open()
        await attempt?.value
        // then
        #expect(!controller.isReady)
        #expect(controller.runtime == nil)
        #expect(controller.cards.first?.model.state == .cancelled)
        #expect(controller.cards.first?.model.message.contains("Late results") == true)
        controller.stop()
    }

    @Test func givenSuspendedOldRequest_whenInputChanges_thenOldCheckCannotOverwriteFreshRequest() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let gate = Gate()
        let controller = QualificationPresentation(session: QualificationSession(repository: Suspended(base: fixture, gate: gate)))
        _ = await controller.discover(.task(options: ["--backend=old"]))
        let attempt = controller.check()
        await gate.waitForEntry()
        // when
        controller.prepare()
        _ = await controller.discover(.task(options: ["--backend=new"]))
        fixture.setReady(true)
        await gate.open()
        await attempt?.value
        // then
        #expect(!controller.isReady)
        #expect(controller.cards.first?.model.identity.hasPrefix("New ·") == true)
        #expect(controller.cards.first?.model.state == .failed)
        controller.stop()
    }

    private struct EmptyPlan: QualificationRepository {
        func runtimeToken() throws -> QualificationRuntimeToken { try QualificationFixture().runtimeToken() }
        func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan {
            BackendQualificationPlan(["qualification_version": .number(1), "discovery_only": .bool(true), "requirements": .array([])])!
        }

        func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws {}
    }

    @Test func givenMissingRequiredOrigins_whenCachedReadCompletes_thenNeverReady() async {
        // given
        for request in [QualificationRequest.task(options: ["--backend=fixture"]), .workflow(name: "fixture", options: [])] {
            let controller = QualificationPresentation(session: QualificationSession(repository: EmptyPlan()))
            // when
            let ready = await controller.discover(request)
            // then
            #expect(!ready)
            #expect(!controller.isReady)
            #expect(controller.cards.first?.model.state == .failed)
            controller.stop()
        }
    }
}
