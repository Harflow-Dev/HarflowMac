import AppKit
import Foundation
@testable import MainWindowFeature
import Testing

/// Synthetic native-fixture diagnostics. No production logger or environment auto-enable exists.
@MainActor
final class ResourceSlotsNativeTrace {
    private struct Record: Encodable {
        let sequence: UInt64
        var lastSequence: UInt64
        var lastUptime: TimeInterval? 
        let uptime: TimeInterval
        let source: String
        let event: String
        let details: [String: String]
        let production: ResourceSlotsDiagnosticRecord?
        let native: NativeSample?
        var repetitions = 1
        var lastProduction: ResourceSlotsDiagnosticRecord?
        var lastNative: NativeSample?
    }

    private struct MandatorySummary: Encodable {
        var count = 0
        var firstSequence: UInt64 = 0
        var lastSequence: UInt64 = 0
        var reasons: [String: Int] = [:]
        var otherReasons = 0
    }

    private struct NativeSample: Encodable {
        let key: Bool
        let active: Bool
        let responder: String
        let frontmostBundleID: String?
        let ownKeyWindowNumber: Int?
        let ownVisibleWindowClasses: [String]
        let displayRefreshRate: Int?
        let attachedIdentity: [String: String]?
        let outerWindowFrame: CGRect
        let contentLayoutRect: CGRect
        let toolbarIdentity: String?
        let chromeDelta: CGSize
        let windowContentFlipped: Bool
        let clipFlipped: Bool?
        let documentFlipped: Bool?
        let rawClipBounds: CGRect?
        let rawDocumentBounds: CGRect?
        let rawDocumentVisibleRect: CGRect?
        let clipBoundsInDocument: CGRect?
        let nativeTopInset: CGFloat?
        let nativeBottomInset: CGFloat?
        let normalizedRawDocumentOffset: CGFloat?
        let normalizedOffsetAfterTopInset: CGFloat?
        let rawOwnerAXScreen: CGRect?
        let rawOwnerAXWindow: CGRect?
        let ownerRectInClip: CGRect?
        let ownerRectInDocument: CGRect?
        let ownerViewportTopY: CGFloat?
        let ownerDocumentTopY: CGFloat?
        let derivedOwnerContentTopY: CGFloat?
        let coordinateIdentityError: CGFloat?
        let visibleGroupHeaders: [String]
        let samplingOrder: String
    }

    private struct Artifact: Encodable {
        let schema = "harflow.resource-slots-native-trace.v2"
        let scenario: String
        let testBodyCompleted: Bool
        let assertionOutcome = "See guarded Swift Testing event stream; body completion does not imply assertions passed"
        let maximumRecords = 705
        let decisiveCapacity = 512
        let perFrameCapacity = 128
        let geometryCapacity = 64
        let firstDeparture: Record?
        let mandatorySummaries: [String: MandatorySummary]
        let decisive: [Record]
        let geometry: [Record]
        let perFrame: [Record]
        let perFrameOverflow: Int
        let diagnosticComplete: Bool
        let observedEvents: UInt64
        let rawDecisiveRecordsDropped: Int
        let rawGeometryRecordsDropped: Int
        let coalescedDecisiveEvents: Int
        let coalescedGeometryEvents: Int
        let truncated: Bool
        let disclosurePressSurvey = "See header-action milestones; absent milestones mean native Press/Space was not reached"
    }

    private weak var fixture: RedesignHost?
    private let state: ResourceSlotsReadingState
    private let scenario: String
    private var sequence: UInt64 = 0
    private var firstDeparture: Record?
    private var mandatory: [String: MandatorySummary] = [:]
    private var decisive: [Record] = []
    private var geometry: [Record] = []
    private var perFrame: [Record] = []
    private var perFrameIndices: [String: Int] = [:]
    private var perFrameOverflow = 0
    private var decisiveDropped = 0
    private var geometryDropped = 0
    private var decisiveCoalesced = 0
    private var geometryCoalesced = 0
    private var tokens: [NSObjectProtocol] = []
    private weak var trackedOwner: NSObject?
    private var finished = false

    init(state: ResourceSlotsReadingState, fixture: RedesignHost, scenario: String) {
        self.state = state
        self.fixture = fixture
        self.scenario = scenario
        state.diagnosticObserver = { [weak self] record in self?.receive(record) }
        let notifications: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "window-became-key"),
            (NSWindow.didResignKeyNotification, "window-resigned-key"),
            (NSWindow.didBecomeMainNotification, "window-became-main"),
            (NSWindow.didResignMainNotification, "window-resigned-main"),
            (NSWindow.willCloseNotification, "window-will-close"),
            (NSApplication.didBecomeActiveNotification, "application-became-active"),
            (NSApplication.didResignActiveNotification, "application-resigned-active")
        ]
        for (name, event) in notifications {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.append(source: "notification", event: event,
                                details: ["ours": String(window === self.fixture?.window),
                                          "windowClass": window.map { String(describing: type(of: $0)) } ?? "none",
                                          "windowNumber": window.map { String($0.windowNumber) } ?? "none"],
                                mandatoryKind: event == "application-resigned-active" || (event == "window-resigned-key" && window === self.fixture?.window)
                                    ? "activation-loss" : nil)
                }
            })
        }
        let keyboardMode = UserDefaults.standard.object(forKey: "AppleKeyboardUIMode").map { String(describing: $0) } ?? "unknown"
        mark("trace-attached", details: ["keyboardMode": keyboardMode])
    }

    func mark(_ event: String, details: [String: String] = [:], owner: NSObject? = nil) {
        if let owner { trackedOwner = owner }
        append(source: "fixture", event: event, details: details)
    }

    func ownerDidUnmount() {
        trackedOwner = nil
    }

    /// Test-side evidence query: how many production events with this name were retained,
    /// including coalesced repetitions. Lets tests count focus lifecycle events per cycle.
    func productionEventCount(_ event: String) -> Int {
        var total = 0
        for record in decisive + geometry + perFrame where (record.production?.event ?? record.event) == event {
            total += max(1, record.repetitions)
        }
        return total
    }

    func observePresentation(owner: NSObject? = nil) {
        if let owner { trackedOwner = owner }
        append(source: "fixture", event: "native-presentation", details: ["targetObservedByExistingOracle": String(owner != nil)], isGeometry: true)
    }

    private func receive(_ record: ResourceSlotsDiagnosticRecord) {
        let kind: String? = record.event == "departure" ? "departure" : record.finishReason == nil ? nil : "terminal"
        append(source: "production", event: record.event, production: record, isGeometry: record.category == .geometry, mandatoryKind: kind)
    }

    private func append(source: String, event: String, details: [String: String] = [:],
                        production: ResourceSlotsDiagnosticRecord? = nil, isGeometry: Bool = false, mandatoryKind: String? = nil) {
        guard !finished else { return }
        sequence += 1
        let record = Record(sequence: sequence, lastSequence: sequence, uptime: ProcessInfo.processInfo.systemUptime,
                            source: source, event: event, details: details, production: production, native: source == "production" ? nil : sample())
        if let mandatoryKind {
            var summary = mandatory[mandatoryKind] ?? MandatorySummary()
            summary.count += 1
            if summary.count == 1 { summary.firstSequence = sequence }
            summary.lastSequence = sequence
            let reason = production?.finishReason?.rawValue ?? event
            if summary.reasons[reason] != nil || summary.reasons.count < 16 {
                summary.reasons[reason, default: 0] += 1
            } else {
                summary.otherReasons += 1
            }
            mandatory[mandatoryKind] = summary
        }
        if event == "departure", firstDeparture == nil { firstDeparture = record; return }
        if let production, isPerFrame(event) {
            retainPerFrame(record, production: production)
        } else if isGeometry, !isProtectedGroup(production) {
            if let last = geometry.last, sameObservation(last, record) {
                geometry[geometry.count - 1].repetitions += 1
                geometry[geometry.count - 1].lastSequence = sequence
                geometry[geometry.count - 1].lastUptime = ProcessInfo.processInfo.systemUptime
                geometry[geometry.count - 1].lastProduction = production
                geometry[geometry.count - 1].lastNative = record.native
                geometryCoalesced += 1
            } else {
                if geometry.count == 64 { geometryDropped += geometry.removeFirst().repetitions }
                geometry.append(record)
            }
        } else if decisive.count < 512 {
            decisive.append(record)
        } else { decisiveDropped += 1 }
    }

    private func retainPerFrame(_ record: Record, production: ResourceSlotsDiagnosticRecord) {
            let target = production.requestedTarget ?? production.callbackTarget
            let encodedTarget = (try? JSONEncoder().encode(target)).flatMap { String(data: $0, encoding: .utf8) } ?? "none"
            let key = [production.generation.uuidString, production.phase, record.event, encodedTarget, production.rejection ?? "none"].joined(separator: "|")
            if let index = perFrameIndices[key] {
                perFrame[index].repetitions += 1
                perFrame[index].lastSequence = sequence
                perFrame[index].lastUptime = ProcessInfo.processInfo.systemUptime
                perFrame[index].lastProduction = production
                perFrame[index].lastNative = record.native
                decisiveCoalesced += 1
            } else if perFrame.count < 128 {
                perFrameIndices[key] = perFrame.count
                perFrame.append(record)
            } else { perFrameOverflow += 1 }
    }

    private func isPerFrame(_ event: String) -> Bool {
        event.contains("presented") || event.hasSuffix("-pending") || event == "focus-request" || event == "owner-frame-rejected"
    }

    private func isProtectedGroup(_ production: ResourceSlotsDiagnosticRecord?) -> Bool {
        guard let production else { return false }
        if production.event.hasPrefix("group-") || production.event.hasPrefix("groups-") { return true }
        if let target = production.callbackTarget, case .group = target { return true }
        return false
    }

    private func sameObservation(_ lhs: Record, _ rhs: Record) -> Bool {
        guard lhs.source == rhs.source, lhs.event == rhs.event, lhs.details == rhs.details else { return false }
        func key(_ record: Record) -> Data? {
            guard let data = try? JSONEncoder().encode(record),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            for key in ["sequence", "lastSequence", "uptime", "repetitions", "lastProduction", "lastNative", "lastUptime"] {
                object.removeValue(forKey: key)
            }
            if var production = object["production"] as? [String: Any] {
                production.removeValue(forKey: "sequence")
                object["production"] = production
            }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        guard let left = key(lhs), let right = key(rhs) else { return false }
        return left == right
    }

    func calibrate(_ control: NSView? = nil) {
        guard let fixture, let scroll = nativeScroll(), let document = scroll.documentView else {
            mark("coordinate-calibration-unavailable"); return
        }
        let clip = scroll.contentView
        let windowRect = clip.convert(clip.bounds, to: nil)
        let screenRect = fixture.window.convertToScreen(windowRect)
        let roundTrip = clip.convert(fixture.window.convertFromScreen(screenRect), from: nil)
        let error = [abs(roundTrip.minX - clip.bounds.minX), abs(roundTrip.minY - clip.bounds.minY),
                     abs(roundTrip.width - clip.bounds.width), abs(roundTrip.height - clip.bounds.height)].max() ?? 0
        #expect(error < 0.5, "Window/screen/clip conversion must round-trip the known clip rectangle")
        var details = ["clipRoundTripError": String(describing: error), "clipFlipped": String(clip.isFlipped),
                       "documentFlipped": String(document.isFlipped)]
        if let control {
            let viewBoundsInClip = control.convert(control.bounds, to: clip)
            let axScreen = control.accessibilityFrame()
            let axInClip = clip.convert(fixture.window.convertFromScreen(axScreen), from: nil)
            let axRoundTrip = fixture.window.convertToScreen(clip.convert(axInClip, to: nil))
            let controlError = [abs(axRoundTrip.minX - axScreen.minX), abs(axRoundTrip.minY - axScreen.minY),
                                abs(axRoundTrip.width - axScreen.width), abs(axRoundTrip.height - axScreen.height)].max() ?? 0
            #expect(controlError < 0.5, "The same native AX rectangle must round-trip through window and clip coordinates")
            details["controlAXRoundTripError"] = String(describing: controlError)
            details["controlAXVersusViewBoundsMinYDelta"] = String(describing: axInClip.minY - viewBoundsInClip.minY)
            details["controlAXVersusViewBoundsMaxYDelta"] = String(describing: axInClip.maxY - viewBoundsInClip.maxY)
        }
        mark("coordinate-calibration", details: details)
    }

    func surveyDisclosure(expandedModel: Bool) {
        guard let fixture else { return }
        var seen = Set<ObjectIdentifier>()
        let nodes = fixture.descendants.flatMap { fixture.elements(in: $0) }.filter { seen.insert(ObjectIdentifier($0)).inserted }
        let triangles = nodes.filter { fixture.string($0, "accessibilityRole") == "AXDisclosureTriangle" }
        let headerButtons = nodes.filter {
            fixture.string($0, "accessibilityRole") == "AXButton"
                && [fixture.string($0, "accessibilityLabel"), fixture.string($0, "accessibilityTitle")]
                .compactMap(\.self)
                .contains { $0.contains("Native resource") || $0.contains("Synthetic observed holdings") }
        }
        mark("disclosure-survey-summary", details: ["triangles": String(triangles.count), "headerButtons": String(headerButtons.count),
                                                    "modelExpanded": String(expandedModel), "pressPerformed": "false"])
        let identified = nodes.filter { fixture.string($0, "accessibilityIdentifier") == "resource-slots-group-native-resource" }
        let surveyed = identified + (triangles + headerButtons).filter { node in !identified.contains { $0 === node } }
        for (index, node) in surveyed.prefix(12).enumerated() {
            let value = NSAccessibility.Attribute(rawValue: "AXValue")
            let expanded = NSAccessibility.Attribute(rawValue: "AXExpanded")
            let pairedReaders = resourceSlotsNativeReaderSurvey(node, fixture: fixture)
            mark("disclosure-modern-legacy-readers", details: pairedReaders)
            mark("disclosure-survey-node", details: [
                "identifier": fixture.string(node, "accessibilityIdentifier") ?? "nil",
                "index": String(index), "role": fixture.string(node, "accessibilityRole") ?? "nil",
                "label": fixture.string(node, "accessibilityLabel") ?? fixture.string(node, "accessibilityTitle") ?? "nil",
                "attributes": String(describing: resourceSlotsLegacyAttributeNames(node)),
                "actions": String(describing: resourceSlotsLegacyActionNames(node)),
                "value": String(describing: resourceSlotsLegacyAttributeValue(node, value)),
                "expanded": String(describing: resourceSlotsLegacyAttributeValue(node, expanded)),
                "valueSettable": String(describing: resourceSlotsLegacyIsAttributeSettable(node, value)),
                "expandedSettable": String(describing: resourceSlotsLegacyIsAttributeSettable(node, expanded))
            ])
        }
    }

    func finish(testBodyCompleted: Bool) {
        guard !finished else { return }
        append(source: "fixture", event: "trace-complete", details: ["testBodyCompleted": String(testBodyCompleted)], mandatoryKind: "terminal")
        state.diagnosticObserver = nil
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
        finished = true
        let artifact = Artifact(scenario: scenario, testBodyCompleted: testBodyCompleted, firstDeparture: firstDeparture,
                                mandatorySummaries: mandatory, decisive: decisive, geometry: geometry, perFrame: perFrame,
                                perFrameOverflow: perFrameOverflow, diagnosticComplete: decisiveDropped == 0 && perFrameOverflow == 0,
                                observedEvents: sequence,
                                rawDecisiveRecordsDropped: decisiveDropped, rawGeometryRecordsDropped: geometryDropped,
                                coalescedDecisiveEvents: decisiveCoalesced, coalescedGeometryEvents: geometryCoalesced,
                                truncated: decisiveDropped > 0 || geometryDropped > 0 || perFrameOverflow > 0)
        if !artifact.diagnosticComplete { Issue.record("Resource slots protected diagnostic channel overflowed; evidence is incomplete") }
        do {
            let path = ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_TRACE_DIR"]
            let directory = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("harflow-resource-slots-traces", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("resource-slots-\(scenario)-\(UUID().uuidString).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(artifact).write(to: url, options: .atomic)
            print("RESOURCE_SLOTS_TRACE artifact=\(url.path) truncated=\(artifact.truncated) events=\(sequence)")
        } catch { Issue.record("Could not serialize synthetic resource-slot trace: \(error)") }
    }

    private func nativeScroll() -> NSScrollView? {
        fixture.flatMap { resourceSlotsAttachedScroll($0)?.scroll }
    }

    private func visibleGroupHeaders(_ fixture: RedesignHost) -> [String] {
        var seen = Set<ObjectIdentifier>()
        let viewport = nativeScroll().map { $0.contentView.convert($0.contentView.bounds, to: nil) }
        return fixture.descendants
.flatMap { fixture.elements(in: $0) }
.filter {
            seen.insert(ObjectIdentifier($0)).inserted
                && (fixture.string($0, "accessibilityIdentifier")?.hasPrefix("resource-slots-group-") ?? false)
        }
.prefix(16)
.map { control in
            let frame = fixture.frame(control)
            let intersects = frame.flatMap { frame in viewport.map { $0.intersects(frame) } }
            return "id=\(fixture.string(control, "accessibilityIdentifier") ?? "nil"), "
                + "role=\(fixture.string(control, "accessibilityRole") ?? "nil"), frame=\(String(describing: frame)), "
                + "intersectsViewport=\(String(describing: intersects))"
        }
    }

    private func sample() -> NativeSample? {
        guard let fixture else { return nil }
        let scroll = nativeScroll()
        let clip = scroll?.contentView
        let document = scroll?.documentView
        let clipInDocument = clip.flatMap { clip in document.map { $0.convert(clip.bounds, from: clip) } }
        let normalizedOffset = clipInDocument.flatMap { rect in document.map { resourceSlotsTraceTopY(rect, in: $0.bounds, flipped: $0.isFlipped) } }
        let owner = trackedOwner
        let rawScreen = (owner as? any NSAccessibilityProtocol)?.accessibilityFrame()
        let rawWindow = rawScreen.map(fixture.window.convertFromScreen)
        let ownerClip = rawWindow.flatMap { rect in clip.map { $0.convert(rect, from: nil) } }
        let ownerDocument = rawWindow.flatMap { rect in document.map { $0.convert(rect, from: nil) } }
        let viewportY = ownerClip.flatMap { rect in clip.map { resourceSlotsTraceTopY(rect, in: $0.bounds, flipped: $0.isFlipped) } }
        let documentY = ownerDocument.flatMap { rect in document.map { resourceSlotsTraceTopY(rect, in: $0.bounds, flipped: $0.isFlipped) } }
        let contentY = normalizedOffset.flatMap { offset in viewportY.map { offset + $0 } }
        return NativeSample(key: fixture.window.isKeyWindow, active: NSApp.isActive,
                            responder: fixture.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
                            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                            ownKeyWindowNumber: NSApp.keyWindow?.windowNumber,
                            ownVisibleWindowClasses: NSApp.windows.filter(\.isVisible).prefix(12).map {
                                "\(type(of: $0))#\($0.windowNumber):key=\($0.isKeyWindow):sheet=\($0.sheetParent != nil)"
                            },
                            displayRefreshRate: fixture.window.screen?.maximumFramesPerSecond,
                            attachedIdentity: resourceSlotsAttachedScroll(fixture)?.details,
                            outerWindowFrame: fixture.window.frame, contentLayoutRect: fixture.window.contentLayoutRect,
                            toolbarIdentity: fixture.window.toolbar.map { String(describing: ObjectIdentifier($0)) },
                            chromeDelta: CGSize(width: fixture.window.frame.width - fixture.host.bounds.width,
                                                height: fixture.window.frame.height - fixture.host.bounds.height),
                            windowContentFlipped: fixture.host.isFlipped, clipFlipped: clip?.isFlipped, documentFlipped: document?.isFlipped,
                            rawClipBounds: clip?.bounds, rawDocumentBounds: document?.bounds, rawDocumentVisibleRect: scroll?.documentVisibleRect,
                            clipBoundsInDocument: clipInDocument, nativeTopInset: scroll?.contentInsets.top, nativeBottomInset: scroll?.contentInsets.bottom,
                            normalizedRawDocumentOffset: normalizedOffset,
                            normalizedOffsetAfterTopInset: normalizedOffset.flatMap { offset in scroll.map { offset + $0.contentInsets.top } },
                            rawOwnerAXScreen: rawScreen, rawOwnerAXWindow: rawWindow, ownerRectInClip: ownerClip,
                            ownerRectInDocument: ownerDocument, ownerViewportTopY: viewportY, ownerDocumentTopY: documentY,
                            derivedOwnerContentTopY: contentY,
                            coordinateIdentityError: contentY.flatMap { y in documentY.map { abs(y - $0) } },
                            visibleGroupHeaders: visibleGroupHeaders(fixture),
                            samplingOrder: "production-or-milestone callback; then native window/clip/document; then AX frame; then conversion")
    }
}

func resourceSlotsTraceTopY(_ rect: CGRect, in bounds: CGRect, flipped: Bool) -> CGFloat {
    flipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
}

struct ResourceSlotsTraceCoordinateTests {
    @Test(arguments: [true, false])
    func givenEquivalentPhysicalRectangles_whenClipOrientationChanges_thenTopOriginCoordinateIsUnchanged(_ flipped: Bool) {
        let bounds = CGRect(x: 0, y: 10, width: 300, height: 200)
        let rectangle = CGRect(x: 12, y: flipped ? 30 : 150, width: 100, height: 40)
        #expect(resourceSlotsTraceTopY(rectangle, in: bounds, flipped: flipped) == 20)
    }
}

struct ResourceSlotsNativeCoordinateProbe {
    let viewportTopY: CGFloat
    let documentTopY: CGFloat
}

@MainActor
func resourceSlotsNativeCoordinateProbe(_ owner: NSObject, fixture: RedesignHost, scroll: NSScrollView) -> ResourceSlotsNativeCoordinateProbe? {
    guard let rect = fixture.frame(owner), let document = scroll.documentView else { return nil }
    let clip = scroll.contentView
    let inClip = clip.convert(rect, from: nil)
    let inDocument = document.convert(rect, from: nil)
    return .init(viewportTopY: resourceSlotsTraceTopY(inClip, in: clip.bounds, flipped: clip.isFlipped),
                 documentTopY: resourceSlotsTraceTopY(inDocument, in: document.bounds, flipped: document.isFlipped))
}
