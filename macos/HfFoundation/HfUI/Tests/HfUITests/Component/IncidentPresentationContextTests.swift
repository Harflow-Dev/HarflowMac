import AppKit
import HfCommon
import HfTestUtilities
@testable import HfUI
import Observation
import SwiftUI
import Testing

// MARK: - IncidentPresentationContextTests

@MainActor @Suite struct IncidentPresentationContextTests {
    @Test func givenNativePresentationContext_whenTwoSourcesPublishAndResolveInOneFrame_thenEveryEventIsConsumed() async throws {
        // given
        let fixture = PresentationFixture()
        defer { fixture.close() }
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.vm.binding != nil }
        let binding = try #require(fixture.vm.binding)
        #expect(fixture.vm.incidents === fixture.incidents)
        // when
        binding.wrappedValue = .incident(source: "workflow-list", message: "List unavailable")
        binding.wrappedValue = .incident(source: "workflow-status", message: "Status unavailable")
        // then: synchronous assertions prove the environment binding processes every setter call.
        #expect(fixture.incidents.failures.map(\.source) == ["workflow-list", "workflow-status"])
        #expect(fixture.incidents.current?.source == "workflow-status")
        fixture.incidents.dismiss()
        binding.wrappedValue = .incidentResolved(source: "workflow-list")
        binding.wrappedValue = .incidentResolved(source: "workflow-status")
        #expect(fixture.incidents.failures.isEmpty)
        #expect(fixture.incidents.current == nil)
    }

    @Test func givenNativeViewModelBridge_whenListRecoveryAndUnrelatedRecoveryPublishTogether_thenRetainedErrorClears() async {
        // given
        let fixture = PresentationFixture()
        defer { fixture.close() }
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.vm.binding != nil }
        fixture.vm.publishViewEvent(.incident(source: "workflow-list", message: "List unavailable"))
        await waitUntil { fixture.incidents.failures.count == 1 }
        fixture.incidents.dismiss()
        // when: reproduces the real sidebar's two same-turn success publications.
        fixture.vm.publishViewEvent(.incidentResolved(source: "workflow-list"))
        fixture.vm.publishViewEvent(.incidentResolved(source: "workflow-status"))
        // then
        await waitUntil { fixture.incidents.failures.isEmpty }
        #expect(fixture.incidents.failures.isEmpty)
    }

    @Test(arguments: [true, false])
    func givenNativeConfirmation_whenIncidentArrives_thenAlertOrDialogRemainsPresented(isAlert: Bool) async throws {
        // given
        let fixture = PresentationFixture()
        defer { fixture.close() }
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.vm.binding != nil }
        let binding = try #require(fixture.vm.binding)
        let content = AlertContent(title: "Confirmation", description: nil) { AlertAction(title: "OK") }
        let confirmation: ViewEvent = isAlert ? .alert(content) : .dialog(content)
        binding.wrappedValue = confirmation
        // when
        binding.wrappedValue = .incident(source: "workflow-list", message: "List unavailable")
        binding.wrappedValue = .incidentResolved(source: "workflow-status")
        // then
        #expect(binding.wrappedValue == confirmation)
        #expect(fixture.incidents.failures.count == 1)
        binding.wrappedValue = .none
    }

    @Test func givenWrappedPresentationContext_whenRepeatedlyMountedAndDetachedWithIdleAndCurrentIncidents_thenTeardownCompletes() async throws {
        // given
        _ = NSApplication.shared
        var detachedFixtures: [PresentationFixture] = []
        // when: retain each host through content removal and window close so SwiftUI observes a real detach.
        for index in 0 ..< 8 {
            let wake = ControlledPresentationWake()
            var instant = Date(timeIntervalSince1970: TimeInterval(index * 10))
            var clockReads = 0
            let incidents = IncidentPresentation()
            if index.isMultiple(of: 2) {
                incidents.report(source: "lifecycle", message: "Current incident \(index)")
            }
            let clock = IncidentPresentationClock(wake: { try await wake.wait() }, now: {
                clockReads += 1
                return instant
            })
            let fixture = PresentationFixture(incidents: incidents, clock: clock)
            await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.vm.binding != nil }
            await waitUntil { wake.pendingCount == 1 }
            fixture.close()
            detachedFixtures.append(fixture)
            await waitUntil { !clock.isMounted }
            #expect(!clock.isMounted)
            await waitUntil { wake.cancelledCount == 1 }
            #expect(wake.cancelledCount == 1)
            instant.addTimeInterval(2)
            wake.release(0)
            await waitUntil { wake.returnedCount == 1 }
            #expect(clockReads == 1)
            #expect(wake.issuedCount == 1)
            #expect(wake.pendingCount == 0)
            if index.isMultiple(of: 2) { #expect(incidents.remaining == 8) }
        }
        // then: detached host and root fixtures remain retained through the full teardown sequence.
    }

}

// MARK: - PresentationFixture

@MainActor private final class PresentationFixture {
    let incidents: IncidentPresentation
    let vm = PresentationFixtureVM()
    let host: NSHostingView<ModifiedContent<PresentationFixtureView, ViewPresentationContextModifier>>
    let window: NSWindow

    init(incidents: IncidentPresentation = IncidentPresentation(), clock: IncidentPresentationClock? = nil) {
        _ = NSApplication.shared
        self.incidents = incidents
        self.host = NSHostingView(rootView: PresentationFixtureView(vm: vm).modifier(ViewPresentationContextModifier(incidents: incidents, clock: clock)))
        self.window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
    }

    func close() { window.contentView = nil; window.close() }
}

// MARK: - PresentationFixtureVM

@MainActor @Observable private final class PresentationFixtureVM: ViewModel {
    var binding: Binding<ViewEvent>?
    var incidents: IncidentPresentation?
}

// MARK: - PresentationFixtureView

private struct PresentationFixtureView: View {
    let vm: PresentationFixtureVM
    @Environment(\.viewEvent) private var viewEvent
    @Environment(\.incidentPresentation) private var incidents
    var body: some View {
        Color.clear
            .onAppear { vm.binding = viewEvent; vm.incidents = incidents }
            .publishViewEvent(from: vm, to: viewEvent)
    }
}
