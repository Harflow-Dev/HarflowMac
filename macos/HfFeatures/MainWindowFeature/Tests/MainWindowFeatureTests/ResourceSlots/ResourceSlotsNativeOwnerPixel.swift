import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

/// Pixel-level support for the native owner control's pressed, disabled, focused and
/// appearance-flip oracles (the owner-focus test file's
/// `givenNativeOwnerButton_whenPressedDisabledFocusedAcrossAppearances...` case). Every
/// sample comes from a shadow-free window-server capture: SwiftUI's `.brightness` pressed
/// feedback is a Core Animation filter, and a synchronous layer render does not reproduce
/// it (verified empirically: the filtered sublayer renders empty, leaving the background),
/// so the window server is the only sampling pipeline that can see the hosted reference's
/// pressed state at all.

/// Drives the real owner representable plus the hosted tinted reference inside the pixel
/// test's own hosting window.
@Observable @MainActor
final class ResourceSlotsOwnerPixelProbe {
    var focusToken: UUID?

    /// The token is read inside a view `body`, so assigning `focusToken` after hosting
    /// re-renders the representable with the pending token.
    func content() -> some View { ResourceSlotsOwnerPixelProbeView(probe: self) }

    func enabledControl(_ window: NSWindow) -> ResourceSlotsOwnerButton.Control? {
        control(identifier: "resource-slots-owner-pixel-enabled", window: window)
    }

    func disabledControl(_ window: NSWindow) -> ResourceSlotsOwnerButton.Control? {
        control(identifier: "resource-slots-owner-pixel-disabled", window: window)
    }
}

// MARK: - ResourceSlotsOwnerPixelProbeView

/// The probe's hosted content: the real owner representable (enabled and disabled) beside a
/// genuine `MonitorButtonStyle(.tinted)` reference.
struct ResourceSlotsOwnerPixelProbeView: View {
    let probe: ResourceSlotsOwnerPixelProbe

    var body: some View {
        VStack(spacing: 24) {
            ResourceSlotsOwnerButton(title: "Open task", label: "Open task Build turn, task-1",
                                     identifier: "resource-slots-owner-pixel-enabled", token: probe.focusToken,
                                     isReady: { true }, authorizedResponder: { nil }, acknowledge: { _ in },
                                     observeFocusGain: { _, _ in }, observeFocusLoss: { _, _ in }, userMovedFocus: {},
                                     action: {})
            ResourceSlotsOwnerButton(title: "Open task", label: "Open task Build turn, task-1",
                                     identifier: "resource-slots-owner-pixel-disabled", token: nil,
                                     isReady: { false }, authorizedResponder: { nil }, acknowledge: { _ in },
                                     observeFocusGain: { _, _ in }, observeFocusLoss: { _, _ in }, userMovedFocus: {},
                                     action: {})
                .disabled(true)
            // The hosted reference the pressed pixels are compared against: a genuine
            // MonitorButtonStyle(.tinted) SwiftUI button in the same window, so a mismatch
            // is the native control's, never the test's own arithmetic.
            Button("Open task") {}
                .buttonStyle(MonitorButtonStyle(.tinted))
                .accessibilityIdentifier("resource-slots-owner-pixel-reference")
        }
        .padding(40)
        .frame(width: 320, height: 240)
        .background(Color.windowBG)
    }
}

extension ResourceSlotsOwnerPixelProbe {
    /// The hosted tinted reference's frame in window coordinates, resolved through the
    /// accessibility tree exactly the way the interaction tests resolve hosted elements.
    func referenceFrame(_ window: NSWindow) -> CGRect? {
        func elements(in object: NSObject) -> [NSObject] {
            let selector = NSSelectorFromString("accessibilityChildren")
            guard object.responds(to: selector),
                  let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [object] }
            return [object] + children.flatMap { elements(in: $0) }
        }
        guard let contentView = window.contentView else { return nil }
        let identifier = NSSelectorFromString("accessibilityIdentifier")
        let match = elements(in: contentView).first { object in
            guard object.responds(to: identifier),
                  let value = object.perform(identifier)?.takeUnretainedValue() as? String else { return false }
            return value == "resource-slots-owner-pixel-reference"
        }
        guard let match else { return nil }
        if let accessible = match as? any NSAccessibilityProtocol {
            return window.convertFromScreen(accessible.accessibilityFrame())
        }
        guard match.responds(to: NSSelectorFromString("accessibilityFrame")),
              let frame = match.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return window.convertFromScreen(frame.rectValue)
    }

    private func control(identifier: String, window: NSWindow) -> ResourceSlotsOwnerButton.Control? {
        var queue = window.contentView.map { [$0] } ?? []
        while let current = queue.popLast() {
            if let candidate = current as? ResourceSlotsOwnerButton.Control,
               candidate.accessibilityIdentifier() == identifier {
                return candidate
            }
            queue.append(contentsOf: current.subviews)
        }
        return nil
    }
}

@MainActor
func fixturelessSettle(_ predicate: @MainActor () -> Bool) async {
    await waitUntil {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        return predicate()
    }
}

@MainActor
func fixturelessSettlePump(_ frames: Int) async {
    var pumped = 0
    await fixturelessSettle { pumped += 1; return pumped >= frames }
}

@MainActor
private func resourceInteractionWindowCapture(_ window: NSWindow) throws -> (bitmap: NSBitmapImageRep, scale: CGFloat) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("owner-pixel-\(UUID().uuidString).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // Exclude the shadow so pixel-to-window geometry is independently defined.
    process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "The owner pixel capture requires a foreground window server")
    defer { try? FileManager.default.removeItem(at: url) }
    let image = try #require(NSBitmapImageRep(data: try Data(contentsOf: url))?.cgImage)
    // The shadow-free capture must map exactly onto the native window frame.
    let scale = CGFloat(image.width) / window.frame.width
    try #require(abs(CGFloat(image.height) / scale - window.frame.height) < 1,
                 "The shadow-free owner capture must map exactly to the native window frame")
    return (NSBitmapImageRep(cgImage: image), scale)
}

/// Captures the window through the window server and waits for the rendered result to stop
/// changing: a live appearance flip cross-fades, and a single capture can read the
/// mid-transition blend (the dark fill once sampled the roughly five percent light tail), so
/// a capture is only used after two consecutive captures agree byte for byte.
@MainActor
private func resourceInteractionStableCapture(_ window: NSWindow) throws -> (bitmap: NSBitmapImageRep, scale: CGFloat) {
    var previous: Data?
    for _ in 0 ..< 16 {
        let capture = try resourceInteractionWindowCapture(window)
        guard let pixels = capture.bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "The owner capture could not be encoded for comparison"])
        }
        if let previous, previous == pixels { return capture }
        previous = pixels
    }
    throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 10,
                  userInfo: [NSLocalizedDescriptionKey: "The owner capture never settled; a live cross-fade may still be running"])
}

/// The live appearance flip's on-screen oracle. With the window flipped to dark, one
/// stability-gated window-server capture samples both the native capsule and the hosted
/// tinted reference in the same flipped window, so whatever the live flip does to the
/// window's on-screen compositing applies to both sides: the two fills must match per
/// channel, and only a capsule that genuinely redrew its dark fill can. A control that never
/// redrew is excluded separately — every channel must sit far below the light fill measured
/// before the flip. The absolute dark palette stays covered on screen where the window server
/// reports it directly: the production dark captures, whose windows are created dark.
@MainActor
func resourceInteractionExpectFlippedFillMatchesTheReference(_ control: ResourceSlotsOwnerButton.Control,
                                                             referenceFrame: CGRect,
                                                             lightFill: NSColor,
                                                             window: NSWindow) throws {
    let capture = try resourceInteractionStableCapture(window)
    let flippedNativeFill = try resourceInteractionModeFill(capture.bitmap, capture.scale,
                                                            windowRect: control.convert(control.bounds, to: nil), window: window)
    let flippedReferenceFill = try resourceInteractionModeFill(capture.bitmap, capture.scale,
                                                               windowRect: referenceFrame, window: window)
    guard let flipped = flippedNativeFill.usingColorSpace(.sRGB), let light = lightFill.usingColorSpace(.sRGB) else {
        throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 19,
                      userInfo: [NSLocalizedDescriptionKey: "The flipped fill could not be converted to sRGB"])
    }
    let movedTowardDark = """
    The flipped capsule must redraw toward the dark palette, not stay at the light fill: \
    flipped rgb(\(Int(flipped.redComponent * 255)), \(Int(flipped.greenComponent * 255)), \
    \(Int(flipped.blueComponent * 255))), light rgb(\(Int(light.redComponent * 255)), \
    \(Int(light.greenComponent * 255)), \(Int(light.blueComponent * 255)))
    """
    try #require(flipped.redComponent < light.redComponent - 0.3
                     && flipped.greenComponent < light.greenComponent - 0.3
                     && flipped.blueComponent < light.blueComponent - 0.3,
                 Comment(rawValue: movedTowardDark))
    try resourceInteractionExpectComponentwise(flippedNativeFill, flippedReferenceFill, tolerance: 0.02,
                                              context: "flipped dark fill vs the hosted tinted reference")
}

@MainActor
func resourceInteractionPixel(_ control: ResourceSlotsOwnerButton.Control,
                              at point: CGPoint, window: NSWindow) throws -> NSColor {
    let capture = try resourceInteractionStableCapture(window)
    return try resourceInteractionPixel(capture.bitmap, capture.scale, control, at: point, window: window)
}

@MainActor
private func resourceInteractionPixel(_ bitmap: NSBitmapImageRep, _ scale: CGFloat,
                                      _ control: ResourceSlotsOwnerButton.Control,
                                      at point: CGPoint, window: NSWindow) throws -> NSColor {
    try resourceInteractionPixel(bitmap, scale, atWindowPoint: control.convert(point, to: nil), window: window)
}

@MainActor
private func resourceInteractionPixel(_ bitmap: NSBitmapImageRep, _ scale: CGFloat,
                                      atWindowPoint point: CGPoint, window: NSWindow) throws -> NSColor {
    // Window points (bottom-left origin) become backing pixels (top-left origin).
    let pixelX = Int(point.x * scale)
    let pixelY = Int((window.frame.height - point.y) * scale)
    guard pixelX >= 0, pixelY >= 0, pixelX < bitmap.pixelsWide, pixelY < bitmap.pixelsHigh,
          let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB)
    else {
        throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "The owner pixel sample fell outside the captured window"])
    }
    return color
}

/// The most frequent exact RGB in the middle band of a window-space rect: the capsule fill
/// dominates that band, so antialiased title pixels cannot skew the sample.
@MainActor
private func resourceInteractionModeFill(_ bitmap: NSBitmapImageRep, _ scale: CGFloat,
                                         windowRect rect: CGRect, window: NSWindow) throws -> NSColor {
    var counts: [Int: Int] = [:]
    var samples: [Int: NSColor] = [:]
    for yOffset in stride(from: -6.0, through: 6.0, by: 2.0) {
        for x in stride(from: rect.minX + 4, to: rect.maxX - 4, by: 1) {
            guard let color = try? resourceInteractionPixel(bitmap, scale,
                                                            atWindowPoint: CGPoint(x: x, y: rect.midY + yOffset),
                                                            window: window) else { continue }
            let key = resourceInteractionColorKey(color)
            counts[key, default: 0] += 1
            samples[key] = color
        }
    }
    let dominant = counts.max { $0.value < $1.value }?.key
    return try #require(dominant.flatMap { samples[$0] }, "The sampled capsule band must contain rendered pixels")
}

/// The darkest ink in the middle band of a window-space rect: the title's fully covered glyph
/// pixels, the same measure for the native capsule and the hosted reference.
@MainActor
private func resourceInteractionDarkestInk(_ bitmap: NSBitmapImageRep, _ scale: CGFloat,
                                           windowRect rect: CGRect, window: NSWindow) throws -> NSColor {
    var darkest: NSColor?
    var darkestLuminance = CGFloat.greatestFiniteMagnitude
    for yOffset in stride(from: -6.0, through: 6.0, by: 2.0) {
        for x in stride(from: rect.minX + 4, to: rect.maxX - 4, by: 1) {
            guard let color = try? resourceInteractionPixel(bitmap, scale,
                                                            atWindowPoint: CGPoint(x: x, y: rect.midY + yOffset),
                                                            window: window) else { continue }
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            if luminance < darkestLuminance { darkestLuminance = luminance; darkest = color }
        }
    }
    return try #require(darkest, "The sampled title band must contain rendered ink")
}

@MainActor
private func resourceInteractionColorKey(_ color: NSColor) -> Int {
    guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
    let red = Int((rgb.redComponent * 255).rounded())
    let green = Int((rgb.greenComponent * 255).rounded())
    let blue = Int((rgb.blueComponent * 255).rounded())
    return red << 16 | green << 8 | blue
}

/// Per-channel comparison against the hosted reference: the per-channel tolerance is the
/// oracle, tighter than the summed `resourceInteractionColorDistance` used for sanity checks,
/// so the specific channel an incorrect feedback gets wrong cannot hide inside a sum.
@MainActor
private func resourceInteractionExpectComponentwise(_ actual: NSColor, _ expected: NSColor,
                                                    tolerance: CGFloat, context: String) throws {
    guard let lhs = actual.usingColorSpace(.sRGB), let rhs = expected.usingColorSpace(.sRGB) else {
        throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 8,
                      userInfo: [NSLocalizedDescriptionKey: "The pressed sample could not be converted to sRGB"])
    }
    let expectedText = "rgb(\(Int(rhs.redComponent * 255)), \(Int(rhs.greenComponent * 255)), \(Int(rhs.blueComponent * 255)))"
    let actualText = "rgb(\(Int(lhs.redComponent * 255)), \(Int(lhs.greenComponent * 255)), \(Int(lhs.blueComponent * 255)))"
    try #require(abs(lhs.redComponent - rhs.redComponent) < tolerance
                     && abs(lhs.greenComponent - rhs.greenComponent) < tolerance
                     && abs(lhs.blueComponent - rhs.blueComponent) < tolerance,
                 "\(context): expected \(expectedText), actual \(actualText), per-channel tolerance \(tolerance)")
}

@MainActor
func resourceInteractionExpectColor(_ color: NSColor, red: UInt32, green: UInt32, blue: UInt32, context: String) throws {
    let tolerance: CGFloat = 0.04
    let expected = "rgb(\(red), \(green), \(blue))"
    let actual = "rgb(\(Int(color.redComponent * 255)), \(Int(color.greenComponent * 255)), \(Int(color.blueComponent * 255)))"
    try #require(abs(color.redComponent - CGFloat(red) / 255) < tolerance
                     && abs(color.greenComponent - CGFloat(green) / 255) < tolerance
                     && abs(color.blueComponent - CGFloat(blue) / 255) < tolerance,
                 "\(context): expected \(expected), actual \(actual)")
}

@MainActor
func resourceInteractionColorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
    guard let lhsColor = lhs.usingColorSpace(.sRGB), let rhsColor = rhs.usingColorSpace(.sRGB) else { return 0 }
    return abs(lhsColor.redComponent - rhsColor.redComponent) + abs(lhsColor.greenComponent - rhsColor.greenComponent)
        + abs(lhsColor.blueComponent - rhsColor.blueComponent)
}

/// Disabled dims the foreground only: the title band's darkest ink must sit at the 50% blend
/// of the accent ink into the capsule fill, not at the raw accent ink.
@MainActor
func resourceInteractionExpectDimmedTitle(enabled: ResourceSlotsOwnerButton.Control,
                                          disabled: ResourceSlotsOwnerButton.Control,
                                          window: NSWindow) throws {
    func darkestTitleInk(_ control: ResourceSlotsOwnerButton.Control, _ bitmap: NSBitmapImageRep, _ scale: CGFloat) throws -> NSColor {
        var darkest: NSColor?
        var darkestLuminance = CGFloat.greatestFiniteMagnitude
        for x in stride(from: CGFloat(2), to: control.bounds.width - 2, by: 1) {
            guard let color = try? resourceInteractionPixel(bitmap, scale, control,
                                                            at: CGPoint(x: x, y: control.bounds.midY), window: window)
            else { continue }
            let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            if luminance < darkestLuminance { darkestLuminance = luminance; darkest = color }
        }
        return try #require(darkest, "The owner title band must contain rendered text")
    }

    let capture = try resourceInteractionStableCapture(window)
    let enabledInk = try darkestTitleInk(enabled, capture.bitmap, capture.scale)
    let disabledInk = try darkestTitleInk(disabled, capture.bitmap, capture.scale)
    let fillSample = try resourceInteractionPixel(capture.bitmap, capture.scale, disabled,
                                                  at: CGPoint(x: 6, y: disabled.bounds.midY), window: window)
    guard let ink = enabledInk.usingColorSpace(.sRGB), let fill = fillSample.usingColorSpace(.sRGB),
          let dimmedInk = disabledInk.usingColorSpace(.sRGB)
    else { throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 4) }
    let blended = NSColor(red: (ink.redComponent + fill.redComponent) / 2,
                          green: (ink.greenComponent + fill.greenComponent) / 2,
                          blue: (ink.blueComponent + fill.blueComponent) / 2, alpha: 1)
    try #require(resourceInteractionColorDistance(dimmedInk, blended) < resourceInteractionColorDistance(dimmedInk, ink),
                 "The disabled title must be dimmed toward the fill, not stay at the enabled accent ink")
}

@MainActor
private func resourceInteractionMouseDown(_ point: CGPoint, window: NSWindow) {
    guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
    window.sendEvent(event)
}

/// Queues the release before the press is sent: NSButton tracks synchronously, so its
/// tracking loop must find the mouse-up in the queue the moment it starts waiting — a missing
/// release would otherwise hang the test inside the cell's tracking loop. The blocking
/// capture runs mid-tracking with the release still queued, so the pressed frame is sampled
/// while the press is genuinely held and the release always arrives.
@MainActor
private func resourceInteractionPostMouseUp(_ point: CGPoint, window: NSWindow) {
    guard let event = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
    NSApp.postEvent(event, atStart: true)
}

/// Samples the native control's pressed fill and title ink from inside the cell's synchronous
/// tracking loop. The mouse-up is queued before the mouse-down, and the pressed observer —
/// serviced by the cell's `highlight` — flushes the pressed frame and captures the window once
/// while the press is held.
@MainActor
private func resourceInteractionPressedNative(_ control: ResourceSlotsOwnerButton.Control,
                                              window: NSWindow) throws -> (fill: NSColor, ink: NSColor) {
    final class PressedEvidence {
        var observed = false
        var fill: NSColor?
        var ink: NSColor?
        var failure: String?
    }
    let evidence = PressedEvidence()
    control.pressedObserver = { [evidence] pressed in
        guard pressed else { return }
        evidence.observed = true
        do {
            window.displayIfNeeded()
            let capture = try resourceInteractionWindowCapture(window)
            let rect = control.convert(control.bounds, to: nil)
            evidence.fill = try resourceInteractionModeFill(capture.bitmap, capture.scale, windowRect: rect, window: window)
            evidence.ink = try resourceInteractionDarkestInk(capture.bitmap, capture.scale, windowRect: rect, window: window)
        } catch {
            evidence.failure = String(describing: error)
        }
    }
    defer { control.pressedObserver = nil }
    let pressPoint = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
    let hitTarget = try #require(window.contentView?.hitTest(pressPoint), "The synthesized press must find a target")
    try #require(hitTarget === control || hitTarget.isDescendant(of: control),
                 "The synthesized press must reach the owner control, not \(hitTarget)")
    resourceInteractionPostMouseUp(pressPoint, window: window)
    resourceInteractionMouseDown(pressPoint, window: window)
    try #require(evidence.observed, "The pressed frame must be observed while the cell is mid-tracking")
    if let failure = evidence.failure {
        throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 11,
                      userInfo: [NSLocalizedDescriptionKey: "The mid-tracking capture failed: \(failure)"])
    }
    guard let fill = evidence.fill, let ink = evidence.ink else {
        throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 12,
                      userInfo: [NSLocalizedDescriptionKey: "The mid-tracking capture produced no samples"])
    }
    return (fill, ink)
}

/// Services the reference press sampling on a timer, in whichever run-loop mode the press
/// leaves running, and posts the release itself so the press can never outlive the sampler.
@MainActor
private final class ResourceInteractionPressedSampler: NSObject {
    private let sampleHandler: @MainActor () throws -> (fill: NSColor, ink: NSColor)
    private let finishHandler: @MainActor () -> Void
    private var sampled = false
    private var released = false
    private(set) var sample: (fill: NSColor, ink: NSColor)?
    private(set) var failure: String?

    init(sample: @escaping @MainActor () throws -> (fill: NSColor, ink: NSColor),
         finish: @escaping @MainActor () -> Void) {
        self.sampleHandler = sample
        self.finishHandler = finish
        super.init()
    }

    var isComplete: Bool { sampled && released }

    func schedule() {
        perform(#selector(performSample), with: nil, afterDelay: 0.15, inModes: [.eventTracking, .default])
        perform(#selector(performFinish), with: nil, afterDelay: 0.35, inModes: [.eventTracking, .default])
    }

    func cancelPending() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(performSample), object: nil)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(performFinish), object: nil)
    }

    @objc private func performSample() {
        guard !sampled else { return }
        sampled = true
        do { sample = try sampleHandler() } catch { failure = String(describing: error) }
    }

    @objc private func performFinish() {
        guard !released else { return }
        released = true
        finishHandler()
    }
}

/// Samples the hosted tinted reference's pressed fill and title ink mid-press. SwiftUI offers
/// no in-tracking callback, so a scheduled sampler services one capture inside the press
/// window and posts the release itself; the performs are registered in both the
/// event-tracking mode (serviced when the press runs a tracking loop) and the default mode
/// (serviced when the hosting view returns immediately), so the sampler always completes
/// within a bounded settle and the press always receives its release.
@MainActor
private func resourceInteractionPressedReference(_ frame: CGRect, window: NSWindow) async throws -> (fill: NSColor, ink: NSColor) {
    let pressPoint = CGPoint(x: frame.midX, y: frame.midY)
    let sampler = ResourceInteractionPressedSampler(
        sample: {
            let capture = try resourceInteractionWindowCapture(window)
            return (fill: try resourceInteractionModeFill(capture.bitmap, capture.scale, windowRect: frame, window: window),
                    ink: try resourceInteractionDarkestInk(capture.bitmap, capture.scale, windowRect: frame, window: window))
        },
        finish: { resourceInteractionPostMouseUp(pressPoint, window: window) })
    sampler.schedule()
    resourceInteractionMouseDown(pressPoint, window: window)
    await fixturelessSettle { sampler.isComplete }
    sampler.cancelPending()
    try #require(sampler.isComplete, "The reference press sampler must complete within a bounded settle")
    if let failure = sampler.failure {
        throw NSError(domain: "ResourceSlotsNativeInteractionTests", code: 13,
                      userInfo: [NSLocalizedDescriptionKey: "The reference mid-press capture failed: \(failure)"])
    }
    return try #require(sampler.sample, "The reference press must produce mid-press samples")
}

/// Compares the native control's pressed pixels against the hosted tinted reference under
/// the window's current appearance. The native control is sampled from inside its cell's
/// synchronous tracking loop — the mouse-up is queued before the mouse-down, so tracking can
/// never block, and the pressed observer serviced by the cell's highlight captures the window
/// once while the press is held — while the reference is sampled mid-press by a scheduled
/// sampler that posts the release itself. Each side must first prove it actually observed the
/// pressed state against its own unpressed baseline.
///
/// Rev 3: the pressed feedback subtracts 0.04 per channel from BOTH the fill and the title
/// ink, exactly like the tinted style's `.brightness(-0.04)`. The ink comparison is the
/// discriminator: the previous fill-only feedback left the title ink unadjusted (accentLink
/// red 0.204 against the pressed 0.164, 0.04 apart), which fails this tolerance while the
/// corrected title ink passes it.
@MainActor
func resourceInteractionExpectPressedPixelsMatchTheTintedReference(_ control: ResourceSlotsOwnerButton.Control,
                                                                   referenceFrame: CGRect,
                                                                   window: NSWindow,
                                                                   appearance: String) async throws {
    let baseline = try resourceInteractionStableCapture(window)
    let nativeWindowRect = control.convert(control.bounds, to: nil)
    let unpressedNativeFill = try resourceInteractionModeFill(baseline.bitmap, baseline.scale,
                                                              windowRect: nativeWindowRect, window: window)
    let unpressedReferenceFill = try resourceInteractionModeFill(baseline.bitmap, baseline.scale,
                                                                 windowRect: referenceFrame, window: window)
    let pressedNative = try resourceInteractionPressedNative(control, window: window)
    let pressedReference = try await resourceInteractionPressedReference(referenceFrame, window: window)
    try #require(resourceInteractionColorDistance(unpressedNativeFill, pressedNative.fill) > 0.02,
                 "The native pressed sample (\(appearance)) must differ from its unpressed fill")
    try #require(resourceInteractionColorDistance(unpressedReferenceFill, pressedReference.fill) > 0.02,
                 "The reference pressed sample (\(appearance)) must differ from its unpressed fill")
    try resourceInteractionExpectComponentwise(pressedNative.fill, pressedReference.fill, tolerance: 0.02,
                                               context: "pressed fill vs the hosted tinted reference (\(appearance))")
    try resourceInteractionExpectComponentwise(pressedNative.ink, pressedReference.ink, tolerance: 0.02,
                                               context: "pressed title ink vs the hosted tinted reference (\(appearance))")
}
