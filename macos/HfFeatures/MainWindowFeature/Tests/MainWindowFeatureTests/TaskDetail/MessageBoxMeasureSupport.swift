import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - Shot

/// A rendered bitmap of a hosting view, read in points (top-left origin) as raw RGB bytes.
@MainActor struct Shot {
    let bitmap: NSBitmapImageRep
    let scale: CGFloat
    let size: CGSize

    init(_ view: NSView) {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        self.bitmap = bitmap
        self.scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        self.size = view.bounds.size
    }

    func rgb(px x: Int, _ y: Int) -> [Int] {
        guard let data = bitmap.bitmapData, x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return [0, 0, 0] }
        let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel
        return [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
    }

    func grid(columns: StrideThrough<Int>, rows: StrideThrough<Int>) -> [Int] {
        rows.flatMap { y in columns.map { x in rgb(at: CGPoint(x: x, y: y)).reduce(0, +) / 3 } }
    }

    func rgb(at point: CGPoint) -> [Int] { rgb(px: Int(point.x * scale), Int(point.y * scale)) }

    static func close(_ lhs: [Int], _ rhs: [Int], _ tolerance: Int) -> Bool {
        zip(lhs, rhs).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// The outer bounds (border included) of the lowest run of `surface`-coloured pixels at least 20 pt tall in the
    /// column at `columnX`, widened to the run's horizontal extent on a row below the corner radius, scanning left
    /// from `columnX` and right from `rightX` (both inside the surface, clear of text and the send button).
    func composerBounds(surface: [Int], columnX: CGFloat, rightX: CGFloat) -> CGRect? {
        let x = Int(columnX * scale)
        // The vertical extent is read 11 pt further in, where the 18 pt corner arc has reached the straight side;
        // text glyphs may interrupt the column, so the walk up from the lowest surface pixel tolerates 12 pt gaps.
        let vertical = Int((columnX + 11) * scale)
        guard let bottom = (0 ..< bitmap.pixelsHigh).last(where: { Self.close(rgb(px: vertical, $0), surface, 1) }) else { return nil }
        var top = bottom
        var gap = 0
        var y = bottom
        while y > 0, CGFloat(gap) < 12 * scale {
            y -= 1
            if Self.close(rgb(px: vertical, y), surface, 1) { top = y; gap = 0 } else { gap += 1 }
        }
        guard CGFloat(bottom - top) >= 20 * scale else { return nil }
        let run = (start: top, end: bottom)
        let row = run.start + Int(19 * scale)
        var left = x
        while left > 0, Self.close(rgb(px: left - 1, row), surface, 1) { left -= 1 }
        var right = Int(rightX * scale)
        guard Self.close(rgb(px: right, row), surface, 1) else { return nil }
        while right < bitmap.pixelsWide - 1, Self.close(rgb(px: right + 1, row), surface, 1) { right += 1 }
        // The 1 pt border sits outside the surface-coloured interior.
        return CGRect(x: CGFloat(left) / scale - 1, y: CGFloat(run.start) / scale - 1,
                      width: CGFloat(right - left + 1) / scale + 2, height: CGFloat(run.end - run.start + 1) / scale + 2)
    }

    /// The horizontal extent of what differs from the band's own background (read at x = 0) inside `band`.
    func inkBounds(inBand band: CGRect) -> (minX: CGFloat, maxX: CGFloat)? {
        var minX = Int.max
        var maxX = -1
        let background0 = Int(band.minX * scale)
        for y in Int(band.minY * scale) ..< Int(band.maxY * scale) {
            let background = rgb(px: background0, y)
            for x in background0 ..< Int(band.maxX * scale) where !Self.close(rgb(px: x, y), background, 5) {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        return maxX >= 0 ? (CGFloat(minX) / scale, CGFloat(maxX + 1) / scale) : nil
    }
}

// MARK: - ComposerMeasure

/// Measurements of a hosted composer that compile against both the standard-only and the styled `MessageBoxView`,
/// so the same code measured the base commit's composer and the current `.standard` one.
@MainActor enum ComposerMeasure {
    struct Standard: Equatable {
        var send: CGRect
        var sendNow: CGRect
        var field: CGRect
        var fieldHeights: [CGFloat]
        var hint: CGRect
        var pixels: [Int]

        var summary: String {
            "send=\(send) sendNow=\(sendNow) field=\(field) heights=\(fieldHeights) hint=\(hint) pixels=\(pixels)"
        }
    }

    static let model = MessageBoxModel(
        canSend: true, canContinue: false, isBusy: false, label: "Message this task",
        hint: "Send queues; Send now requests immediate delivery when safe", placeholder: "Queue a message…",
        buttonLabel: "Send"
    )

    static func editableField(in page: RedesignHost) -> NSTextField? {
        page.descendants.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    static func type(_ text: String, into field: NSTextField, in page: RedesignHost) async {
        _ = page.window.makeFirstResponder(field)
        field.stringValue = text
        field.currentEditor()?.string = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        var passes = 0
        await page.settle { passes += 1; return passes >= 6 }
    }

    static func frame(_ label: String, in page: RedesignHost) -> CGRect {
        page.element(label).flatMap { page.frame($0) }.map { page.host.convert($0, from: nil) } ?? .zero
    }

    /// A 20 pt mask of a 1400 x 800 render of the loading skeleton: "#" where the pixel differs from the page
    /// background (read in the right margin), "." elsewhere. The shimmer pulses its alpha with a wall clock even
    /// under Reduce Motion, so values are not stable but the shapes are.
    static func skeletonMask(dark: Bool, make: () -> AnyView) async throws -> [String] {
        let size = CGSize(width: 1400, height: 800)
        let page = RedesignHost(make()
.preferredColorScheme(dark ? .dark : .light)
.environment(\.hfReduceMotionOverride, true)
                                    .environment(\.shimmerReduceMotionOverride, true), size: size, appearance: dark ? .dark : .light)
        defer { page.close() }
        await DisplayFrames.waitForPresentedFrame()
        func mask() -> [String] {
            let shot = Shot(page.host)
            let background = shot.rgb(at: CGPoint(x: 1390, y: 400))
            return stride(from: 2, to: 800, by: 20).map { y in
                String(stride(from: 2, to: 1400, by: 20).map { x in
                    Shot.close(shot.rgb(at: CGPoint(x: x, y: y)), background, 1) ? "." : "#"
                })
            }
        }
        // Card and bubble fills settle a few frames after the first presentation: read until two reads agree.
        var previous: [String] = []
        var current: [String] = []
        for _ in 0 ..< 20 {
            var passes = 0
            await page.settle { passes += 1; return passes >= 15 }
            current = mask()
            if current == previous { break }
            previous = current
        }
        return current
    }

    /// Geometry and sampled pixels of the standard composer at 1400 x 600 for one appearance, built by `make`
    /// (the caller supplies the composer so the base commit's initialiser can be used unchanged).
    static func standard(dark: Bool, make: (MessageBoxModel) -> AnyView) async throws -> Standard {
        let size = CGSize(width: 1400, height: 600)
        let view = make(model).preferredColorScheme(dark ? .dark : .light).environment(\.hfReduceMotionOverride, true)
        let page = RedesignHost(view, size: size, appearance: dark ? .dark : .light)
        defer { page.close() }
        await page.settle { editableField(in: page) != nil }
        let field = try #require(editableField(in: page))
        await DisplayFrames.waitForPresentedFrame()
        var passes = 0
        await page.settle { passes += 1; return passes >= 10 }
        var heights: [CGFloat] = []
        for lines in 1 ... 3 {
            await type(String(repeating: "line\n", count: lines - 1) + "line", into: field, in: page)
            heights.append(field.convert(field.bounds, to: page.host).height)
        }
        await type("", into: field, in: page)
        let shot = Shot(page.host)
        let fieldFrame = field.convert(field.bounds, to: page.host)
        let send = frame("Send", in: page)
        let pixels = shot.grid(columns: stride(from: 300, through: 1100, by: 100), rows: stride(from: 490, through: 599, by: 15))
        return Standard(send: send, sendNow: frame("Send now", in: page), field: fieldFrame, fieldHeights: heights,
                        hint: frame(model.hint + " · ⌘↩ to send", in: page), pixels: pixels)
    }
}
