import AppKit
import HfUI
@testable import MainWindowFeature
import SwiftUI

// MARK: - LayerMotionFixture

/// A titled window with an explicit appearance and a plain, non-flipped container, ordered front.
@MainActor final class LayerMotionFixture {
    let window: NSWindow
    let container: NSView

    init(appearance: NSAppearance.Name = .aqua, size: CGSize = CGSize(width: 320, height: 200)) {
        _ = NSApplication.shared
        self.container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        self.window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = container
        window.orderFront(nil)
    }

    private var previousEnhancedInterface: Any?
    private var changedEnhancedInterface = false
    private static let enhancedInterface = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    /// Makes SwiftUI publish its accessibility tree in this process; undone by `close()`.
    func enableAccessibility() {
        guard !changedEnhancedInterface else { return }
        previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(Self.enhancedInterface)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedInterface)
        changedEnhancedInterface = true
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.contentView = nil
        window.close()
        if changedEnhancedInterface {
            NSApplication.shared.accessibilitySetValue(previousEnhancedInterface, forAttribute: Self.enhancedInterface)
            changedEnhancedInterface = false
        }
    }

    /// Whether the window is on screen. Occlusion is recorded but not required: it may not report
    /// visible in a hosted run.
    var isOnScreen: Bool { window.isVisible }
}

// MARK: - LayerMotionProbe

/// Reads the indicator animations off a layer tree.
@MainActor enum LayerMotionProbe {
    static let keys: Set<String> = [LayerCaretView.animationKey, LayerSpinnerView.animationKey, LayerPulseDotView.animationKey]

    /// Every `(layer, key)` below `root` (views and their sublayers) carrying an indicator animation.
    static func animations(in root: NSView) -> [(layer: CALayer, key: String)] {
        var seen = Set<ObjectIdentifier>()
        var result: [(CALayer, String)] = []
        func walk(_ layer: CALayer) {
            guard seen.insert(ObjectIdentifier(layer)).inserted else { return }
            for key in layer.animationKeys() ?? [] where keys.contains(key) { result.append((layer, key)) }
            layer.sublayers?.forEach(walk)
        }
        for view in activityNativeDescendants(root) { if let layer = view.layer { walk(layer) } }
        return result
    }

    static func count(in root: NSView) -> Int { animations(in: root).count }

    /// Whether `layer` itself carries any animation.
    static func hasAnimation(_ layer: CALayer?) -> Bool { !(layer?.animationKeys() ?? []).isEmpty }

    static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        activityNativeDescendants(root).compactMap { $0 as? T }
    }

    /// The reference-date phase of `period`, and the layer's local time under `animation`: both read
    /// back-to-back so that they differ only by the few microseconds between the two reads.
    static func phaseError(layer: CALayer, animation: CAAnimation, period: TimeInterval) -> TimeInterval {
        let local = layer.convertTime(CACurrentMediaTime(), from: nil) - animation.beginTime
        let reference = Date().timeIntervalSinceReferenceDate
        var difference = (local - reference).truncatingRemainder(dividingBy: period)
        if difference > period / 2 { difference -= period }
        if difference < -period / 2 { difference += period }
        return abs(difference)
    }
}

// MARK: - LayerMotionBitmap

/// A rendered raster in premultiplied RGBA components, top row first.
struct LayerMotionBitmap {
    let width: Int
    let height: Int
    let scale: CGFloat
    private(set) var components: [Double]

    /// A `cacheDisplay` raster, colour-converted into sRGB by drawing its image into an sRGB context.
    @MainActor init?(rep: NSBitmapImageRep, scale: CGFloat) {
        guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        self.init(context: context, scale: scale)
    }

    /// Reads a premultiplied RGBA sRGB bitmap context (row 0 is the top row).
    init?(context: CGContext, scale: CGFloat) {
        guard let data = context.data else { return nil }
        self.width = context.width
        self.height = context.height
        self.scale = scale
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        var values = [Double](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                for channel in 0 ..< 4 { values[(y * width + x) * 4 + channel] = Double(bytes[y * rowBytes + x * 4 + channel]) / 255 }
            }
        }
        self.components = values
    }

    func alpha(x: Int, y: Int) -> Double { components[(y * width + x) * 4 + 3] }

    /// The ink bounds in points (pixels whose alpha exceeds `threshold`), or `nil` when blank.
    func inkBounds(threshold: Double = 0.02) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where alpha(x: x, y: y) > threshold {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Total alpha, in square points.
    var inkArea: Double { stride(from: 3, to: components.count, by: 4).reduce(0) { $0 + components[$1] } / Double(scale * scale) }

    /// The largest per-component difference, in 8-bit levels.
    func maxDifference(from other: LayerMotionBitmap) -> Double {
        guard width == other.width, height == other.height else { return 255 }
        var worst = 0.0
        for index in components.indices { worst = max(worst, abs(components[index] - other.components[index])) }
        return worst * 255
    }

    /// Mean absolute per-component difference, in 8-bit levels.
    func meanDifference(from other: LayerMotionBitmap) -> Double {
        guard width == other.width, height == other.height else { return 255 }
        var sum = 0.0
        for index in components.indices { sum += abs(components[index] - other.components[index]) }
        return sum / Double(components.count) * 255
    }

    /// The same raster with every premultiplied component scaled by `opacity`.
    func applyingOpacity(_ opacity: Double) -> LayerMotionBitmap {
        var copy = self
        copy.components = components.map { $0 * opacity }
        return copy
    }

    /// The straight (unpremultiplied) colour of the most opaque pixel, optionally within a top-down
    /// rectangle given in points.
    func strongestInkColor(in region: CGRect? = nil) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var best = -1
        var bestAlpha = 0.0
        let left = region.map { max(0, Int($0.minX * scale)) } ?? 0
        let right = region.map { min(width, Int($0.maxX * scale)) } ?? width
        let top = region.map { max(0, Int($0.minY * scale)) } ?? 0
        let bottom = region.map { min(height, Int($0.maxY * scale)) } ?? height
        for y in top ..< bottom {
            for x in left ..< right {
                let index = (y * width + x) * 4 + 3
                if components[index] > bestAlpha {
                    bestAlpha = components[index]
                    best = index - 3
                }
            }
        }
        guard best >= 0, bestAlpha > 0 else { return nil }
        return (components[best] / bestAlpha, components[best + 1] / bestAlpha, components[best + 2] / bestAlpha, bestAlpha)
    }
}

// MARK: - Rendering

/// Renders layer-backed content for comparison. Core Animation composites in the render server, so a
/// running animation cannot be captured; these renders read the model layers, which is what a frozen
/// rotation or opacity is.
@MainActor enum LayerMotionRender {
    /// `container`'s layer tree, rendered upright into a bitmap at the window's backing scale, under
    /// the container's effective appearance.
    static func layerTree(of container: NSView) -> LayerMotionBitmap? {
        let scale = container.window?.backingScaleFactor ?? 2
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        guard let layer = container.layer, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int((container.bounds.width * scale).rounded()),
                                      height: Int((container.bounds.height * scale).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        container.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        return LayerMotionBitmap(context: context, scale: scale)
    }

    /// A view's own display (SwiftUI hosting views), as `cacheDisplay` draws it.
    static func display(of view: NSView) -> LayerMotionBitmap? {
        let scale = view.window?.backingScaleFactor ?? 2
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return LayerMotionBitmap(rep: rep, scale: scale)
    }
}

// MARK: - Layer inspection

extension CALayer {
    /// The point `local` of this layer as seen from `ancestor`, in `ancestor`'s coordinates.
    func point(_ local: CGPoint, in ancestor: CALayer) -> CGPoint { convert(local, to: ancestor) }
}

extension CAMediaTimingFunction {
    /// The four control values, for comparing two timing functions.
    var controlValues: [Float] {
        (0 ..< 4).flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            getControlPoint(at: index, values: &point)
            return point
        }
    }
}
