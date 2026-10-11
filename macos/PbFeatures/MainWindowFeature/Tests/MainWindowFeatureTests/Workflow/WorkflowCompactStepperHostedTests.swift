import AppKit
@testable import MainWindowFeature
import ObjectiveC
import Observation
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowCompactStepperHostedTests

@MainActor @Suite(.serialized) struct WorkflowCompactStepperHostedTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenCompactStepper_whenNativeActionsRun_thenValueIsSpokenOnceAndOriginalRangeIsEnforced(appearance: ColorScheme) async throws {
        // given
        let state = HostedStepperState()
        let fixture = RedesignHost(
            WorkflowCompactStepper(label: "Decision attempts", value: Binding(get: { state.value }, set: { state.value = $0 }), range: 1 ... 3)
                .preferredColorScheme(appearance), size: CGSize(width: 288, height: 100)
        )
        defer { fixture.close() }
        await fixture.settle {
            uniqueElements(fixture).contains { fixture.string($0, "accessibilityRole") == "AXIncrementor" }
        }
        let tree = uniqueElements(fixture)
        let incrementors = tree.filter { fixture.string($0, "accessibilityRole") == "AXIncrementor" }
        let control = try #require(incrementors.first)

        // then: the decorative count is not an additional accessible value or label.
        #expect(incrementors.count == 1)
        #expect(fixture.string(control, "accessibilityLabel") == "Decision attempts")
        #expect(value(control) == 2)
        #expect(tree.filter {
            fixture.string($0, "accessibilityRole") == "AXStaticText"
                && (fixture.string($0, "accessibilityValue") == "2" || fixture.string($0, "accessibilityLabel") == "2")
        }
.isEmpty)

        // when / then: drive native increment/decrement, including both original boundaries.
        try await apply("accessibilityPerformIncrement", on: control, expecting: 3, state: state, fixture: fixture)
        try await apply("accessibilityPerformIncrement", on: control, expecting: 3, state: state, fixture: fixture)
        try await apply("accessibilityPerformDecrement", on: control, expecting: 2, state: state, fixture: fixture)
        try await apply("accessibilityPerformDecrement", on: control, expecting: 1, state: state, fixture: fixture)
        try await apply("accessibilityPerformDecrement", on: control, expecting: 1, state: state, fixture: fixture)
    }

    private func uniqueElements(_ fixture: RedesignHost) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return fixture.descendants.flatMap { fixture.elements(in: $0) }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func apply(_ name: String, on element: NSObject, expecting expected: Int,
                       state: HostedStepperState, fixture: RedesignHost) async throws {
        try action(name, on: element)
        await fixture.settle { state.value == expected && value(element) == expected }
        #expect(state.value == expected)
        #expect(value(element) == expected, "The native spoken value must match the bound value after every action")
    }

    private func action(_ name: String, on element: NSObject) throws {
        if let accessible = element as? any NSAccessibilityProtocol {
            // The installed SDK declares BOOL, but the native cell returned false while its
            // binding changed. Verify the actual bound and spoken outcome, not that return.
            if name == "accessibilityPerformIncrement" {
                _ = accessible.accessibilityPerformIncrement()
            } else {
                _ = accessible.accessibilityPerformDecrement()
            }
            return
        }
        let selector = NSSelectorFromString(name)
        try #require(element.responds(to: selector))
        let method = try #require(class_getInstanceMethod(type(of: element), selector))
        let encoding = String(cString: try #require(method_getTypeEncoding(method)))
        if encoding.hasPrefix("B") || encoding.hasPrefix("c") {
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            let implementation = unsafeBitCast(element.method(for: selector), to: Action.self)
            _ = implementation(element, selector)
        } else {
            try #require(encoding.hasPrefix("v"), "Unsupported actual native action ABI: \(encoding)")
            typealias Action = @convention(c) (AnyObject, Selector) -> Void
            let implementation = unsafeBitCast(element.method(for: selector), to: Action.self)
            implementation(element, selector)
        }
    }

    private func value(_ element: NSObject) -> Int? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard element.responds(to: selector) else { return nil }
        return (element.perform(selector)?.takeUnretainedValue() as? NSNumber)?.intValue
    }
}

// MARK: - HostedStepperState

@MainActor @Observable private final class HostedStepperState { var value = 2 }
