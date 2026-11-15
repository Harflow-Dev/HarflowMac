import AppKit
import ObjectiveC

// MARK: - ActivityFeedArrivalFadeSpy

/// Records every `activityArrival` animation added to any layer, through a pass-through swizzle of
/// `CALayer.add(_:forKey:)` installed once per process. A layer removes the animation again after
/// its 0.18 s duration, so counting the adds is how a test proves that a fade did or did not play
/// at any moment, not only while it is still running. Layers are held weakly. The counts are
/// process-global, so the spy relies on serial suite execution (`--no-parallel`).
enum ActivityFeedArrivalFadeSpy {
    private struct Record { weak var layer: CALayer? }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var records: [Record] = []

    static let install: Void = {
        let selector = #selector(CALayer.add(_:forKey:))
        guard let method = class_getInstanceMethod(CALayer.self, selector) else { return }
        typealias Original = @convention(c) (CALayer, Selector, CAAnimation, String?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (CALayer, CAAnimation, String?) -> Void = { layer, animation, key in
            if key == "activityArrival" { record(layer) }
            original(layer, selector, animation, key)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }()

    private static func record(_ layer: CALayer) {
        lock.lock()
        records.append(Record(layer: layer))
        lock.unlock()
    }

    /// Forgets everything recorded so far.
    static func reset() {
        lock.lock()
        records = []
        lock.unlock()
    }

    /// Every arrival fade added since the last `reset()`.
    static var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    /// The arrival fades added to `layer` itself since the last `reset()`.
    static func count(on layer: CALayer?) -> Int {
        guard let layer else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.layer === layer }.count
    }
}
