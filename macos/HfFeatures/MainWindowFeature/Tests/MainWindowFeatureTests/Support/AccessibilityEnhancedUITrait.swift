import AppKit
import Testing

// MARK: - AccessibilityEnhancedUITrait

/// SwiftUI builds its accessibility tree only while accessibility is enabled for the process, so
/// suites that find content through accessibility nodes enable it themselves instead of depending
/// on an external assistive client.
struct AccessibilityEnhancedUITrait: TestTrait, SuiteTrait, TestScoping {
    let isRecursive = true

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let previous = await MainActor.run { PreviousAccessibilityValue.enable() }
        do {
            try await function()
        } catch {
            await MainActor.run { previous.restore() }
            throw error
        }
        await MainActor.run { previous.restore() }
    }
}

extension Trait where Self == AccessibilityEnhancedUITrait {
    static var accessibilityEnhancedUI: Self { Self() }
}

// MARK: - PreviousAccessibilityValue

private struct PreviousAccessibilityValue: Sendable {
    private static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    let value: Bool?

    @MainActor
    static func enable() -> Self {
        let previous = NSApplication.shared.accessibilityAttributeValue(enhanced) as? Bool
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        return Self(value: previous)
    }

    @MainActor
    func restore() {
        NSApplication.shared.accessibilitySetValue(value, forAttribute: Self.enhanced)
    }
}
