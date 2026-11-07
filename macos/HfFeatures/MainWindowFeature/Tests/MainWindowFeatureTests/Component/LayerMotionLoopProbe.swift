import AppKit
@testable import MainWindowFeature
import ObjectiveC

// MARK: - LayerMotionLoopProbe

/// Test-only counter of the layout calls that make up the feed's SwiftUI re-measure loop: a root
/// `fittingSize`, `updateConstraints` and `layout` on hosting views, feed platform hosts and native
/// cells. It wraps the Objective-C implementations of the classes it is given (once per class and
/// selector), counts only while armed, and never counts the layer-motion views themselves.
///
/// The wrappers are process-global. Each hosted suite runs in its own process (the guarded runner
/// admits exactly one hosted suite per host launch), so nothing leaks between suites; within a suite
/// every user calls `uninstall()` in a `defer`, which restores every original implementation. An
/// unarmed probe costs one lock and a flag read per call: it never classifies the view.
enum LayerMotionLoopProbe {
    struct Counts: Equatable {
        var fittingSize = 0
        var updateConstraints = 0
        var layout = 0

        var total: Int { fittingSize + updateConstraints + layout }
        static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(fittingSize: lhs.fittingSize - rhs.fittingSize, updateConstraints: lhs.updateConstraints - rhs.updateConstraints,
                   layout: lhs.layout - rhs.layout)
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var counts = Counts()
    private nonisolated(unsafe) static var byType: [String: Int] = [:]
    private nonisolated(unsafe) static var armed = false
    private nonisolated(unsafe) static var wrapped = Set<String>()
    private nonisolated(unsafe) static var originals: [(method: Method, implementation: IMP)] = []

    static var snapshot: Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// Counted calls per `Type.selector` since the last `resetBreakdown()`.
    static var breakdown: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return byType
    }

    static func resetBreakdown() {
        lock.lock()
        byType = [:]
        lock.unlock()
    }

    static func arm(_ value: Bool) {
        lock.lock()
        armed = value
        lock.unlock()
    }

    /// Wraps `type` and every superclass that implements the selectors itself, up to `NSView`.
    @MainActor static func install(on type: AnyClass) {
        var current: AnyClass? = type
        while let cls = current, cls !== NSObject.self {
            wrapFitting(cls)
            wrapVoid(cls, #selector(NSView.updateConstraints), name: "updateConstraints") { counts.updateConstraints += 1 }
            wrapVoid(cls, #selector(NSView.layout), name: "layout") { counts.layout += 1 }
            if cls === NSView.self { break }
            current = class_getSuperclass(cls)
        }
    }

    /// Disarms the probe and puts every original implementation back.
    static func uninstall() {
        lock.lock()
        armed = false
        for entry in originals { method_setImplementation(entry.method, entry.implementation) }
        originals = []
        wrapped = []
        counts = Counts()
        byType = [:]
        lock.unlock()
    }

    private static func ownsMethod(_ cls: AnyClass, _ selector: Selector) -> Method? {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return nil }
        defer { free(list) }
        for index in 0 ..< Int(count) where method_getName(list[index]) == selector { return list[index] }
        return nil
    }

    private static func isCounted(_ view: NSView) -> Bool {
        MainActor.assumeIsolated {
            if view is LayerMotionView { return false }
            let name = NSStringFromClass(type(of: view))
            return name.contains("NSHostingView") || name.contains("PlatformViewHost") || name.contains("Cell")
                || view.subviews.first is NSScrollView
        }
    }

    private static func isArmed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed
    }

    private static func record(_ view: NSView, _ name: String, _ bump: () -> Void) {
        guard isArmed(), isCounted(view) else { return }
        let key = MainActor.assumeIsolated { "\(NSStringFromClass(type(of: view))).\(name)" }
        lock.lock()
        if armed {
            bump()
            byType[key, default: 0] += 1
        }
        lock.unlock()
    }

    private static func wrapFitting(_ cls: AnyClass) {
        let selector = #selector(getter: NSView.fittingSize)
        let key = "\(NSStringFromClass(cls))|fittingSize"
        guard let method = ownsMethod(cls, selector), wrapped.insert(key).inserted else { return }
        typealias Function = @convention(c) (NSView, Selector) -> NSSize
        let implementation = method_getImplementation(method)
        originals.append((method, implementation))
        let original = unsafeBitCast(implementation, to: Function.self)
        let block: @convention(block) (NSView) -> NSSize = { view in
            record(view, "fittingSize") { counts.fittingSize += 1 }
            return original(view, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func wrapVoid(_ cls: AnyClass, _ selector: Selector, name: String, _ bump: @escaping () -> Void) {
        let key = "\(NSStringFromClass(cls))|\(name)"
        guard let method = ownsMethod(cls, selector), wrapped.insert(key).inserted else { return }
        typealias Function = @convention(c) (NSView, Selector) -> Void
        let implementation = method_getImplementation(method)
        originals.append((method, implementation))
        let original = unsafeBitCast(implementation, to: Function.self)
        let block: @convention(block) (NSView) -> Void = { view in
            record(view, name, bump)
            original(view, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
