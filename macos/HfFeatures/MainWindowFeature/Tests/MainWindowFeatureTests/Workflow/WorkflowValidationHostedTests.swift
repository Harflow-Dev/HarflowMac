import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowValidationHostedTests

@MainActor @Suite(.serialized) struct WorkflowValidationHostedTests {
    nonisolated static let states: [WorkflowValidationState] = [
        .nameRequired, .checking,
        .invalid("Node ‘Review’ has no outgoing connection. " + String(repeating: "Review its connections. ", count: 8)),
        .unavailable("The validator did not respond.")
    ]

    nonisolated static let surfaces = [
        WorkflowValidationSurface(isDark: false, size: CGSize(width: 1000, height: 620)),
        WorkflowValidationSurface(isDark: true, size: CGSize(width: 1000, height: 620)),
        WorkflowValidationSurface(isDark: false, size: CGSize(width: 1440, height: 900)),
        WorkflowValidationSurface(isDark: true, size: CGSize(width: 1440, height: 900))
    ]

    @Test(arguments: states, surfaces)
    func givenUnreadyWorkflow_whenHosted_thenStatusExplainsWhySaveIsDisabled(state: WorkflowValidationState, surface: WorkflowValidationSurface) async throws {
        // given
        let vm = WorkflowPreview.make(run: false)
        vm.didDisappear()
        vm.name = state == .nameRequired ? "" : "Draft"
        vm.validationState = state
        let fixture = RedesignHost(VStack {
            WorkflowView(vm).saveButton
            WorkflowValidationStatus(viewModel: vm)
        }
        .padding()
        .frame(width: surface.size.width, height: surface.size.height)
        .background(Color(nsColor: .windowBackgroundColor)), size: surface.size, appearance: surface.isDark ? .dark : .light)
        defer { fixture.close(); vm.didDisappear() }
        // when
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 5) { NSApp.isActive && fixture.window.isKeyWindow }
        try #require(NSApp.isActive && fixture.window.isKeyWindow)
        let message = try #require(state.message)
        await fixture.settle { fixture.hasElement(containing: message) }
        // then
        #expect(!vm.canSave)
        #expect(fixture.hasElement(containing: message))
        let expectedSaveLabel = if case .invalid = state {
            "Save, fix the problem first"
        } else {
            "Save"
        }
        let save = try #require(fixture.element(expectedSaveLabel))
        #expect(fixture.string(save, "accessibilityLabel") == expectedSaveLabel)
        // SwiftUI AX nodes expose the getter without NSAccessibilityProtocol conformance.
        try #require(save.responds(to: NSSelectorFromString("isAccessibilityEnabled")))
        let enabled = try #require(save.value(forKey: "accessibilityEnabled") as? NSNumber)
        #expect(!enabled.boolValue)
        if state.glyph != nil {
            #expect(fixture.element(state.accessibilityLabel) != nil)
        }
        let status = try #require(fixture.descendants.flatMap { fixture.elements(in: $0) }.first {
            fixture.string($0, "accessibilityLabel")?.contains(message) == true
                || fixture.string($0, "accessibilityValue")?.contains(message) == true
        })
        let frame = try #require(fixture.frame(status))
        #expect(frame.width > 0 && frame.maxX <= fixture.window.contentLayoutRect.maxX + 1)
        try await capture(fixture, state: state, surface: surface)
    }

    private func capture(_ fixture: RedesignHost, state: WorkflowValidationState, surface: WorkflowValidationSurface) async throws {
        let actualSize = fixture.window.contentLayoutRect.size
        try #require(abs(actualSize.width - surface.size.width) <= 1)
        try #require(abs(actualSize.height - surface.size.height) <= 1)
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_WORKFLOW_VALIDATION_CAPTURE_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateName: String
        switch state {
        case .nameRequired: stateName = "name-required"
        case .checking: stateName = "checking"
        case .invalid: stateName = "invalid-long-reason"
        case .unavailable: stateName = "validate-unavailable"
        case .inactive, .valid:
            Issue.record("Validation capture matrix contains an unexpected ready state")
            return
        }
        let scheme = surface.isDark ? "dark" : "light"
        let name = "workflow-validation-\(stateName)-\(scheme)-\(Int(surface.size.width))x\(Int(surface.size.height))"
        try await M04NativeWindowEvidence.record(window: fixture.window, name: name, directory: directory)
    }
}

// MARK: - WorkflowValidationSurface

struct WorkflowValidationSurface: Sendable {
    let isDark: Bool
    let size: CGSize
}
