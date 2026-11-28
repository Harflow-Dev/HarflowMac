import AppKit
import Foundation
@testable import MainWindowFeature

// MARK: - ResourceSlotsShellEvidence

/// Timeline evidence for the F-RS-FKA-RETURN qualification: every responder change, every input
/// the test sends (tagged), every production focus diagnostic and the return cycle they belong
/// to. Observation runs continuously from `start()` to `stop()`.
///
/// Known limit of the outside-input guard: a window-scoped `NSEvent` local monitor cannot see
/// events consumed inside nested tracking loops, and events the test sends with
/// `window.sendEvent` never reach it. A clean guard therefore rules out physical input that
/// went through the normal event loop, not input swallowed by a tracking loop.
@MainActor
final class ResourceSlotsShellEvidence {
    enum Region: String { case none, window, content, toolbar, other }

    struct ResponderRecord: Equatable {
        let className: String
        let identity: ObjectIdentifier?
        let region: Region
        let ancestors: [String]
        var summary: String { "\(className)@\(region.rawValue)" + (region == .other ? "<\(ancestors.joined(separator: ">"))" : "") }
    }

    struct AXSample {
        let identifier: String?
        let role: String?
        let text: String?
        let delay: TimeInterval
    }

    struct ResponderChange {
        let seq: Int
        let time: TimeInterval
        let cycle: Int
        let token: UUID?
        let source: String
        let from: ResponderRecord
        let to: ResponderRecord
        let fromIsOwner: Bool
        let toIsOwner: Bool
        var accessibility: AXSample?
    }

    struct InputRecord {
        let index: Int
        let tag: String
        let kind: String
        let keyCode: UInt16?
        let target: String
        let responderAtSend: String
        let backGesture: Bool
        let enqueuedAt: TimeInterval
        let startSeq: Int
        var deliveryStartSeq: Int?
        var endSeq: Int?
        var deliveredAt: TimeInterval?
        var release: String?
        /// Which matcher clause tied a monitor observation to this posted event.
        var matchClause: String?
    }

    struct DiagnosticEntry {
        let seq: Int
        let time: TimeInterval
        let event: String
        let cycle: Int
        let token: UUID?
    }

    struct Cycle {
        let id: Int
        let authorizedSeq: Int
        let authorizedAt: TimeInterval
        let authorizedResponder: ResponderRecord
        /// The production `focus-authorized` diagnostic's resign outcome and authorized responder kind.
        let resign: String
        let authorizedKind: String
        var requestToken: UUID?
        var requestSeq: Int?
        var terminalEvent: String?
        var terminalSeq: Int?
    }

    static let terminalEvents: Set<String> = ["focus-restored", "focus-user-moved", "user-cancel", "focus-budget-exhausted"]

    let fixture: any ResourceSlotsNativeHosting
    private let state: ResourceSlotsReadingState
    let variant: String
    private(set) var seq = 0
    private(set) var changes: [ResponderChange] = []
    var inputs: [InputRecord] = []
    private(set) var diagnostics: [DiagnosticEntry] = []
    private(set) var stamps: [(seq: Int, time: TimeInterval, text: String)] = []
    private(set) var cycles: [Cycle] = []
    private(set) var counts: [String: Int] = [:]
    private(set) var outsideInput: [String] = []
    var gestureCompleteSeq: Int?
    private(set) var gestureRelease: String?
    /// The leak recorded by an earlier variant of this run, when there was one.
    let priorLeakedEvent: String?
    /// Full fields of every posted event and of every monitor observation, in order.
    private(set) var eventLog: [(seq: Int, text: String)] = []
    /// One line describing the expected and the observed starting transition; set by the flow.
    var startOracleLine: String?
    private(set) var contentHostDescription = "unresolved"
    private var contentHost: NSView?
    private var lastResponder: ResponderRecord
    private var observation: NSKeyValueObservation?
    private var monitor: Any?
    struct TaggedEvent {
        let index: Int
        let event: NSEvent
        let type: NSEvent.EventType
        let eventNumber: Int?
        let keyCode: UInt16?
        let timestamp: TimeInterval
        let windowNumber: Int
        let location: CGPoint
    }

    /// Set when a posted release was neither observed nor found in the queue: it may still be
    /// pending somewhere, so outside input in later variants of the same run cannot be trusted.
    static var possibleLeakedEvent: String?

    var tagged: [TaggedEvent] = []
    /// Index of the posted release that ends the pointer Back gesture, while it is awaited.
    var pendingGestureRelease: Int?
    /// Set when the delivery of the posted release could not be established.
    var gestureUnresolved: String?
    /// Set when the queue changed while the release was being dispatched; the variant is then unresolved.
    var queueDisturbed = false
    /// Whether a responder is the owner control under test; set by the flow.
    var isOwnerResponder: ((NSResponder?) -> Bool)?
    private weak var lastResponderObject: NSResponder?
    private var lastWasOwner = false
    var nextMouseNumber = 0x7E57_0000
    private var running = false

    init(fixture: any ResourceSlotsNativeHosting, state: ResourceSlotsReadingState, trace: ResourceSlotsNativeTrace, variant: String) {
        self.fixture = fixture
        self.state = state
        self.variant = variant
        self.priorLeakedEvent = Self.possibleLeakedEvent
        self.lastResponder = .init(className: "nil", identity: nil, region: .none, ancestors: [])
        trace.productionTap = { [weak self] record in self?.receive(record) }
    }

    func next() -> Int {
        seq += 1
        return seq
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var currentCycle: Cycle? { cycles.last }
    func count(_ event: String) -> Int { counts[event, default: 0] }

    func stamp(_ kind: String, _ detail: String = "") {
        stamps.append((next(), now, detail.isEmpty ? kind : "\(kind): \(detail)"))
    }

    // MARK: Lifecycle

    /// Records the class of the content hosting view and its distance from the owner control.
    func chooseContentHost(owner: NSView) {
        var hops = 0
        var node: NSView? = owner
        while let view = node {
            let name = String(describing: type(of: view))
            if name.contains("HostingView"), !Self.isInToolbar(view) {
                contentHost = view
                contentHostDescription = "\(name) at \(hops) superview hops from \(String(describing: type(of: owner)))"
                return
            }
            hops += 1
            node = view.superview
        }
        contentHostDescription = "no NSHostingView ancestor of \(String(describing: type(of: owner)))"
    }

    func start() {
        guard !running else { return }
        running = true
        lastResponder = describe(fixture.window.firstResponder)
        lastResponderObject = fixture.window.firstResponder
        lastWasOwner = isOwnerResponder?(fixture.window.firstResponder) ?? false
        stamp("evidence-start", lastResponder.summary)
        let window = fixture.window
        observation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sampleResponder(source: "kvo") }
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                           .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }

    func stop() {
        guard running else { return }
        running = false
        sampleResponder(source: "stop")
        observation?.invalidate()
        observation = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stamp("evidence-stop")
    }

    // MARK: Responder log

    private static let toolbarClassNames: Set<String> = ["NSToolbarView", "NSToolbarItemViewer"]

    /// Whether the view or an ancestor is one of AppKit's toolbar view classes.
    static func isInToolbar(_ view: NSView) -> Bool {
        var node: NSView? = view
        while let current = node {
            if toolbarClassNames.contains(NSStringFromClass(type(of: current))) { return true }
            node = current.superview
        }
        return false
    }

    func describe(_ responder: NSResponder?) -> ResponderRecord {
        guard let responder else { return .init(className: "nil", identity: nil, region: .none, ancestors: []) }
        let name = String(describing: type(of: responder))
        if responder === fixture.window { return .init(className: name, identity: ObjectIdentifier(responder), region: .window, ancestors: []) }
        guard let view = responder as? NSView else {
            return .init(className: name, identity: ObjectIdentifier(responder), region: .other, ancestors: [])
        }
        var chain: [String] = []
        let toolbar = Self.isInToolbar(view)
        var node: NSView? = view
        while let current = node {
            chain.append(String(describing: type(of: current)))
            node = current.superview
        }
        let inContent = contentHost.map { view.isDescendant(of: $0) } ?? false
        let region: Region = toolbar ? .toolbar : inContent ? .content : .other
        return .init(className: name, identity: ObjectIdentifier(responder), region: region, ancestors: Array(chain.prefix(8)))
    }

    func sampleResponder(source: String) {
        let object = fixture.window.firstResponder
        guard object !== lastResponderObject || (object == nil) != (lastResponder.identity == nil) else { return }
        let current = describe(object)
        let toIsOwner = isOwnerResponder?(object) ?? false
        let change = ResponderChange(seq: next(), time: now, cycle: cycles.last?.id ?? 0, token: cycles.last?.requestToken,
                                     source: source, from: lastResponder, to: current, fromIsOwner: lastWasOwner,
                                     toIsOwner: toIsOwner, accessibility: nil)
        lastResponder = current
        lastResponderObject = object
        lastWasOwner = toIsOwner
        changes.append(change)
        let index = changes.count - 1
        let started = now
        // The accessibility read is deferred so it cannot run inside the responder change itself.
        Task { @MainActor [weak self] in
            guard let self, index < changes.count else { return }
            let element = resourceSlotsNativeFocusedElement(fixture)
            changes[index].accessibility = AXSample(
                identifier: element.flatMap { self.fixture.string($0, "accessibilityIdentifier") },
                role: element.flatMap { self.fixture.string($0, "accessibilityRole") },
                text: element.flatMap { self.fixture.string($0, "accessibilityLabel") ?? self.fixture.string($0, "accessibilityTitle") },
                delay: now - started)
        }
    }

    // MARK: Production diagnostics

    private func receive(_ record: ResourceSlotsDiagnosticRecord) {
        sampleResponder(source: "diagnostic")
        let sequence = next()
        counts[record.event, default: 0] += 1
        switch record.event {
        case "focus-authorized":
            cycles.append(Cycle(id: cycles.count + 1, authorizedSeq: sequence, authorizedAt: now,
                                authorizedResponder: describe(state.focusReturnAuthorizedResponder),
                                resign: record.focusResign?.rawValue ?? "none",
                                authorizedKind: record.focusAuthorizedKind?.rawValue ?? "none"))
        case "focus-request":
            if !cycles.isEmpty {
                cycles[cycles.count - 1].requestToken = state.focusReturnRequest?.token
                cycles[cycles.count - 1].requestSeq = sequence
            }
        case let event where Self.terminalEvents.contains(event):
            if !cycles.isEmpty, cycles[cycles.count - 1].terminalEvent == nil {
                cycles[cycles.count - 1].terminalEvent = event
                cycles[cycles.count - 1].terminalSeq = sequence
            }
        default: break
        }
        if Self.recorded.contains(record.event) {
            diagnostics.append(.init(seq: sequence, time: now, event: record.event, cycle: cycles.last?.id ?? 0,
                                     token: cycles.last?.requestToken))
        }
    }

    private static let recorded: Set<String> = ["focus-authorized", "focus-request", "focus-restored", "focus-user-moved",
                                                "user-cancel", "focus-budget-exhausted", "focus-acknowledge-ignored", "mount", "unmount",
                                                "departure"]

    // MARK: Tagged input

    private func tagKey(_ event: NSEvent) -> String {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            "m|\(event.type.rawValue)|\(event.eventNumber)"
        default:
            "k|\(event.type.rawValue)|\(event.keyCode)|\(event.timestamp.bitPattern)"
        }
    }

    private static func isMouse(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: true
        default: false
        }
    }

    private static let locationTolerance: CGFloat = 0.5
    private static let timestampTolerance: TimeInterval = 0.001

    /// The clause by which `event` is the tagged event, or `nil`. One fixed rule serves both the
    /// monitor and the queue peek. Identity always matches. A mouse event matches by type, window
    /// number and location (within 0.5 pt) plus an equal event number or a timestamp within 1 ms.
    /// A key event matches by type, key code and exact timestamp.
    func matchClause(_ entry: TaggedEvent, _ event: NSEvent) -> String? {
        if entry.event === event { return "identity" }
        guard entry.type == event.type else { return nil }
        guard Self.isMouse(event.type) else {
            return entry.keyCode == event.keyCode && entry.timestamp == event.timestamp ? "type+keyCode+timestamp" : nil
        }
        guard entry.windowNumber == event.windowNumber,
              abs(entry.location.x - event.locationInWindow.x) <= Self.locationTolerance,
              abs(entry.location.y - event.locationInWindow.y) <= Self.locationTolerance
        else { return nil }
        if let number = entry.eventNumber, number == event.eventNumber { return "type+window+location+eventNumber" }
        if abs(entry.timestamp - event.timestamp) < Self.timestampTolerance { return "type+window+location+timestamp" }
        return nil
    }

    private func taggedMatch(for event: NSEvent) -> (index: Int, clause: String)? {
        for entry in tagged {
            if let clause = matchClause(entry, event) { return (entry.index, clause) }
        }
        return nil
    }

    /// Every field the matcher can use, at full precision.
    func fields(_ event: NSEvent) -> String {
        var parts = ["type=\(event.type.rawValue)", "window=\(event.windowNumber)", String(format: "timestamp=%.9f", event.timestamp)]
        if Self.isMouse(event.type) {
            parts.append(String(format: "location=%.4f,%.4f", event.locationInWindow.x, event.locationInWindow.y))
            parts.append("eventNumber=\(event.eventNumber)")
            parts.append("clickCount=\(event.clickCount)")
        } else if event.type == .keyDown || event.type == .keyUp {
            parts.append("keyCode=\(event.keyCode)")
        }
        return parts.joined(separator: " ")
    }

    func log(_ text: String) {
        eventLog.append((next(), text))
    }

    @discardableResult
    func register(_ event: NSEvent, kind: String, target: String, backGesture: Bool) -> Int {
        sampleResponder(source: "pre-input")
        let tag = tagKey(event)
        let isKey = event.type == .keyDown || event.type == .keyUp
        let record = InputRecord(index: inputs.count, tag: tag, kind: kind,
                                 keyCode: isKey ? event.keyCode : nil,
                                 target: target, responderAtSend: lastResponder.summary, backGesture: backGesture,
                                 enqueuedAt: now, startSeq: next())
        tagged.append(TaggedEvent(index: record.index, event: event, type: event.type,
                                  eventNumber: Self.isMouse(event.type) ? event.eventNumber : nil,
                                  keyCode: isKey ? event.keyCode : nil, timestamp: event.timestamp,
                                  windowNumber: event.windowNumber, location: event.locationInWindow))
        inputs.append(record)
        log("posted #\(record.index) \(kind): " + fields(event))
        return record.index
    }

    func finish(_ index: Int, release: String? = nil, endSeq: Int? = nil) {
        inputs[index].endSeq = endSeq ?? next()
        inputs[index].deliveredAt = now
        if let release { inputs[index].release = release }
        sampleResponder(source: "post-input")
    }

    private func observe(_ event: NSEvent) {
        guard event.window === fixture.window || event.windowNumber == fixture.window.windowNumber else { return }
        if let (index, clause) = taggedMatch(for: event) {
            log("monitor observed #\(index) (matched by \(clause)): " + fields(event))
            if inputs[index].release == nil {
                inputs[index].matchClause = clause
                inputs[index].deliveryStartSeq = next()
                inputs[index].deliveredAt = now
                inputs[index].release = "dispatched"
                if index == pendingGestureRelease {
                    // Completion is stamped after the release has been dispatched, from the run loop.
                    RunLoop.main.perform { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self, let pending = self.pendingGestureRelease else { return }
                            self.pendingGestureRelease = nil
                            self.inputs[pending].endSeq = self.next()
                            self.completeGesture(release: "mouse release dispatched")
                        }
                    }
                }
            }
            return
        }
        log("monitor observed untagged: " + fields(event))
        outsideInput.append("\(event.type.rawValue)@\(String(format: "%.3f", now))")
        stamp("outside-input", "type=\(event.type.rawValue) keyCode=\(event.type == .keyDown || event.type == .keyUp ? Int(event.keyCode) : -1)")
    }

    private func keyEvent(_ type: NSEvent.EventType, _ characters: String, _ code: UInt16) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: now, windowNumber: fixture.window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    func sendTab(target: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = keyEvent(type, "\t", 48) else { return }
            let index = register(event, kind: type == .keyDown ? "keyDown Tab" : "keyUp Tab", target: target, backGesture: false)
            fixture.window.sendEvent(event)
            finish(index, release: "sendEvent")
        }
    }

    func sendSpace(target: String, backGesture: Bool) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = keyEvent(type, " ", 49) else { return }
            let index = register(event, kind: type == .keyDown ? "keyDown Space" : "keyUp Space", target: target, backGesture: backGesture)
            fixture.window.sendEvent(event)
            finish(index, release: "sendEvent")
        }
        if backGesture { completeGesture(release: "key release delivered") }
    }

    private func completeGesture(release: String, at seq: Int? = nil) {
        gestureCompleteSeq = seq ?? next()
        gestureRelease = release
        stamp("back-gesture-complete", release)
    }

    // MARK: Cycle queries

    /// Which phase of the Back gesture was running when the return was authorized.
    func backFiredPhase(_ cycle: Cycle) -> String {
        let gesture = inputs.filter(\.backGesture)
        guard !gesture.isEmpty else { return "no Back gesture recorded" }
        // Enqueue intervals are not delivery intervals: a posted release counts only once its delivery began.
        for input in gesture {
            let isPostedRelease = input.kind.hasPrefix("mouseUp")
            guard !isPostedRelease || input.deliveryStartSeq != nil else { continue }
            let start = isPostedRelease ? (input.deliveryStartSeq ?? input.startSeq) : input.startSeq
            guard start <= cycle.authorizedSeq, cycle.authorizedSeq <= (input.endSeq ?? Int.max) else { continue }
            if isPostedRelease { return "during the release (dispatched)" }
            return "during \(input.kind)"
        }
        if let last = gesture.compactMap(\.endSeq).max(), cycle.authorizedSeq > last { return "after the gesture completed" }
        return "between gesture events"
    }

    /// When the owner became first responder at or after `time`; `nil` if it did not.
    func ownerAcquiredAt(since time: TimeInterval, until limit: TimeInterval) -> TimeInterval? {
        if let first = changes.first(where: { $0.toIsOwner && $0.time >= time && $0.time <= limit }) { return first.time }
        return changes.last { $0.time < time }?.toIsOwner == true ? time : nil
    }

    /// Whether any recorded transition left the owner in `[time, limit]`.
    func leftOwner(since time: TimeInterval, until limit: TimeInterval = .infinity) -> Bool {
        changes.contains { $0.fromIsOwner && !$0.toIsOwner && $0.time >= time && $0.time <= limit }
    }

    /// Inputs sent after authorization that are not part of the Back gesture, up to `limit`.
    func independentInputs(after authorizedSeq: Int, before limit: Int) -> [String] {
        inputs.filter { !$0.backGesture && $0.startSeq > authorizedSeq && $0.startSeq < limit }.map(\.kind)
    }

    /// Responder changes between authorization and the limit sequence, in order.
    func transitions(after authorizedSeq: Int, before limit: Int) -> [ResponderChange] {
        changes.filter { $0.seq > authorizedSeq && $0.seq < limit }
    }
}
