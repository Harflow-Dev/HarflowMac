import AppKit
import HfTestUtilities
import HfUI
@testable import SettingsFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized)
struct SettingsQualificationHostedTests {
    @Test func givenQualificationStates_whenActualSettingsHosted_thenCardsUseScrollableList() async throws {
        // given
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        for state in [HarnessQualificationModel.State.ready, .failed, .unsupported] {
            let vm = HarnessesViewModelMock(rows: [], serverPath: nil)
            vm.qualificationCards = [.init(id: "fixture", model: .init(identity: "Fixture harness · fixture version", state: state,
                message: "Fixture qualification", features: [.init(id: "fixture_feature", result: state.title)]))]
            let host = NSHostingView(rootView: AnyView(HarnessesView(vm).environment(\.hfReduceMotionOverride, true)))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 460),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            // when
            await DisplayFrames.waitForPresentedFrame()
            await waitUntil(timeout: 5) {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                return accessibilityStrings(in: host).contains("Fixture harness · fixture version")
            }
            // then
            #expect(descendants(host).contains { $0 is NSScrollView })
            #expect(accessibilityStrings(in: host).contains("Fixture harness · fixture version"))
            if let output = ProcessInfo.processInfo.environment["HARFLOW_QUALIFICATION_RENDER_OUTPUT"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("settings-\(state.rawValue).png"))
            }
        }
    }

    private func accessibilityStrings(in host: NSView) -> Set<String> {
        var strings: Set<String> = []
        var visited: Set<ObjectIdentifier> = []
        func collect(_ element: NSObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            for key in ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"] where element.responds(to: NSSelectorFromString(key)) {
                if let value = element.value(forKey: key) as? String { strings.insert(value) }
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [NSObject] {
                children.forEach(collect)
            }
            if let view = element as? NSView { view.subviews.forEach(collect) }
        }
        collect(host)
        return strings
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
