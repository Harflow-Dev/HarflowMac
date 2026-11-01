import AppKit
import CoreGraphics
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

extension ActivityFeedApprovalHostedTests {
    @Test(arguments: [false, true])
    func givenIsolatedProductionResourceSkeleton_whenNativeFramesAreSampled_thenMotionChangesPixelsAndReduceMotionStaysStatic(
        _ reduceMotion: Bool
    ) async throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_NATIVE_INTERACTION"] == "1" else { return }
        let probe = try ResourceSlotsSkeletonPixelProbe(reduceMotion: reduceMotion)
        defer { probe.fixture.close() }
        try await probe.foregroundAndQualifyShapes()
        try await probe.sampleMotion(reduceMotion: reduceMotion)
    }
}

@MainActor
private final class ResourceSlotsSkeletonPixelProbe {
    let fixture: RedesignHost
    private let directory: URL
    private let prefix: String
    private var baseline: SkeletonPixels?
    private var mask: [Int] = []
    private var evidence: [String] = []

    init(reduceMotion: Bool) throws {
        self.directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_CAPTURE_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("harflow-resource-slots-motion").path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.prefix = "resource-slots-motion-\(reduceMotion)"
        self.fixture = RedesignHost(ResourceSlotsSkeleton(reduceMotion: reduceMotion)
            .padding(24)
.frame(width: 700, height: 620)
.background(Color.windowBG)
            .environment(\.hfReduceMotionOverride, reduceMotion)
.preferredColorScheme(.light),
            size: CGSize(width: 700, height: 620), appearance: .light)
    }

    func foregroundAndQualifyShapes() async throws {
        NSApp.setActivationPolicy(.regular)
        fixture.window.isOpaque = true
        fixture.window.backgroundColor = .windowBackgroundColor
        fixture.window.center()
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { self.fixture.window.isKeyWindow && NSApp.isActive }
        // Always preserve actual pixels before a readiness assertion can abort.
        _ = try capture("initial")
        try requireVisibleHost()
        var failure: Error?
        var captures = 0
        await fixture.settle {
            guard captures < 8 else { return true }
            captures += 1
            do {
                let pixels = try self.capture("readiness-\(captures)")
                let rows = pixels.barRows
                self.evidence.append("readiness=\(captures), bands=\(rows), measuredContrast=\(pixels.contrastRange); requiredMin=4/255; "
                                         + "ROI x90...180,y32...570; reference x500...520")
                if rows.count >= 4 {
                    self.baseline = pixels
                    self.mask = rows.flatMap { range in
                        (range.lowerBound + 2 ..< range.upperBound - 1).flatMap { y in
                            stride(from: 90, through: 180, by: 3).map { y * 700 + $0 }
                        }
                    }
                    return true
                }
            } catch { failure = error; return true }
            return false
        }
        try persistEvidence()
        if let failure { throw failure }
        try #require(baseline != nil && !mask.isEmpty, "Native PNG must show at least four pale horizontal skeleton bars at production geometry")
    }

    func sampleMotion(reduceMotion: Bool) async throws {
        defer { try? persistEvidence() }
        let baseline = try #require(baseline)
        let started = ProcessInfo.processInfo.systemUptime
        var nextSample: TimeInterval = 0
        var count = 0
        var shapePeak = 0
        var backgroundPeak = 0
        var failure: Error?
        await waitUntil(timeout: 4) {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard count < 24, elapsed < 4 else { return true }
            guard elapsed >= nextSample else { return false }
            do {
                try self.requireVisibleHost()
                let pixels = try self.capture("sample-\(count)")
                let shapeDelta = pixels.maximumDelta(from: baseline, indices: self.mask)
                let backgroundDelta = pixels.maximumDelta(from: baseline, indices: SkeletonPixels.backgroundIndices)
                shapePeak = max(shapePeak, shapeDelta)
                backgroundPeak = max(backgroundPeak, backgroundDelta)
                self.evidence.append("sample=\(count), elapsed=\(elapsed), shapeDelta=\(shapeDelta), backgroundDelta=\(backgroundDelta)")
                count += 1
                // Unequal intervals avoid repeatedly sampling one phase of the 1.4-second production sweep.
                nextSample = elapsed + [0.083, 0.137, 0.101][count % 3]
            } catch { failure = error; return true }
            return elapsed >= 2.1 && count >= 8
        }
        if let failure { throw failure }
        try #require(ProcessInfo.processInfo.systemUptime - started >= 2.1 && count >= 8,
                     "Native motion evidence must span at least 1.5 complete shimmer cycles")
        try #require(backgroundPeak <= 1, "Independent blank-card ROI changed: capture noise/occlusion prevents a trustworthy motion verdict")
        if reduceMotion {
            #expect(shapePeak <= 1, "Reduce Motion must keep verified production bar interiors static within the independent pixel noise floor")
        } else {
            #expect(shapePeak > max(3, backgroundPeak + 2), "Full-motion shimmer must change verified bar pixels above the independent noise floor")
        }
    }

    private func requireVisibleHost() throws {
        try #require(NSApp.isActive && fixture.window.isKeyWindow && fixture.window.isVisible
            && fixture.window.occlusionState.contains(.visible), "Motion host must remain active, key and visible")
        let frame = fixture.window.frame
        try #require(NSScreen.screens.contains { $0.visibleFrame.contains(frame) }, "Motion host must be entirely on-screen")
        let screenTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let windowRect = CGRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height)
        let above = try #require(CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                            CGWindowID(fixture.window.windowNumber)) as? [[String: Any]],
                                 "Native window ordering must be readable to establish unobscured capture")
        let overlapping = above.filter { item in
            guard (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = item[kCGWindowBounds as String] as? [String: NSNumber] else { return false }
            let rect = CGRect(x: bounds["X"]?.doubleValue ?? 0, y: bounds["Y"]?.doubleValue ?? 0,
                              width: bounds["Width"]?.doubleValue ?? 0, height: bounds["Height"]?.doubleValue ?? 0)
            return rect.intersects(windowRect)
        }
        try #require(overlapping.isEmpty, "An on-screen native window overlaps the motion fixture; evidence is inconclusive")
    }

    private func capture(_ suffix: String) throws -> SkeletonPixels {
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()
        let url = directory.appendingPathComponent(prefix + "-" + suffix + ".png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // Exclude the shadow so pixel-to-window geometry is independently defined.
        process.arguments = ["-x", "-o", "-l", String(fixture.window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try SkeletonPixels(url: url, fixture: fixture)
    }

    private func persistEvidence() throws {
        try evidence.joined(separator: "\n").write(to: directory.appendingPathComponent(prefix + "-measurements.txt"), atomically: true, encoding: .utf8)
    }
}

private struct SkeletonPixels {
    let rgb: [[Int]]
    static let backgroundIndices = (80 ... 560).flatMap { y in stride(from: 500, through: 520, by: 4).map { y * 700 + $0 } }

    @MainActor init(url: URL, fixture: RedesignHost) throws {
        let data = try Data(contentsOf: url)
        let image = try #require(NSBitmapImageRep(data: data)?.cgImage)
        let scale = CGFloat(image.width) / fixture.window.frame.width
        try #require(abs(CGFloat(image.height) / scale - fixture.window.frame.height) < 1,
                     "Shadow-free PNG must map exactly to the native window before content cropping")
        let height = Int((620 * scale).rounded())
        let content = try #require(image.cropping(to: CGRect(x: 0, y: CGFloat(image.height - height), width: CGFloat(image.width), height: CGFloat(height))))
        let bitmap = NSBitmapImageRep(cgImage: content)
        var values = Array(repeating: [0, 0, 0], count: 700 * 620)
        let barIndices = (32 ... 570).flatMap { y in stride(from: 90, through: 180, by: 3).map { y * 700 + $0 } }
        let references = (32 ... 570).map { $0 * 700 + 510 }
        for index in Set(barIndices + references + Self.backgroundIndices) {
            let x = index % 700
            let y = index / 700
            let color = try #require(bitmap.colorAt(x: Int((CGFloat(x) + 0.5) * scale), y: Int((CGFloat(y) + 0.5) * scale))?.usingColorSpace(.deviceRGB))
            values[index] = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        self.rgb = values
    }

    var barRows: [ClosedRange<Int>] {
        // Production neutralFill #ECECEF against cardFill #FFFFFF gives 16–19 levels;
        // four levels allow sheen/quantization while requiring a measurable horizontal shape.
        let matches = (32 ... 570).filter { y in
            let reference = rgb[y * 700 + 510]
            return stride(from: 90, through: 180, by: 15).allSatisfy { x in
                zip(reference, rgb[y * 700 + x]).allSatisfy { $0 - $1 >= 4 }
            }
        }
        var bands: [ClosedRange<Int>] = []
        for row in matches {
            if let previous = bands.last, previous.upperBound + 1 == row {
                bands[bands.count - 1] = previous.lowerBound ... row
            } else { bands.append(row ... row) }
        }
        return bands.filter { (6 ... 16).contains($0.count) }
    }

    var contrastRange: String {
        let contrasts = barRows.flatMap { band in
            band.flatMap { y in
                stride(from: 90, through: 180, by: 15).flatMap { x in
                    zip(rgb[y * 700 + 510], rgb[y * 700 + x]).map { $0 - $1 }
                }
            }
        }
        return "\(contrasts.min() ?? 0)...\(contrasts.max() ?? 0)/255"
    }

    func maximumDelta(from baseline: Self, indices: [Int]) -> Int {
        indices.reduce(0) { peak, index in
            max(peak, zip(rgb[index], baseline.rgb[index]).map { abs($0 - $1) }.max() ?? 0)
        }
    }
}
