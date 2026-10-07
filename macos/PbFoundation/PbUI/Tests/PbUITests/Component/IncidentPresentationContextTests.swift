import AppKit
import Observation
import PbCommon
import PbTestUtilities
@testable import PbUI
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

}

// MARK: - PresentationFixture

@MainActor private final class PresentationFixture {
    let incidents = IncidentPresentation()
    let vm = PresentationFixtureVM()
    let host: NSHostingView<ModifiedContent<PresentationFixtureView, ViewPresentationContextModifier>>
    let window: NSWindow

    init() {
        _ = NSApplication.shared
        self.host = NSHostingView(rootView: PresentationFixtureView(vm: vm).modifier(ViewPresentationContextModifier(incidents: incidents)))
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
}

// MARK: - PresentationFixtureView

private struct PresentationFixtureView: View {
    let vm: PresentationFixtureVM
    @Environment(\.viewEvent) private var viewEvent
    var body: some View {
        Color.clear
            .onAppear { vm.binding = viewEvent }
            .publishViewEvent(from: vm, to: viewEvent)
    }
}
