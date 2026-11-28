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
    private(set) var inputs: [InputRecord] = []
    private(set) var diagnostics: [DiagnosticEntry] = []
    private(set) var stamps: [(seq: Int, time: TimeInterval, text: String)] = []
    private(set) var cycles: [Cycle] = []
    private(set) var counts: [String: Int] = [:]
    private(set) var outsideInput: [String] = []
    private(set) var gestureCompleteSeq: Int?
    private(set) var gestureRelease: String?
    private(set) var contentHostDescription = "unresolved"
    private var contentHost: NSView?
    private var lastResponder: ResponderRecord
    private var observation: NSKeyValueObservation?
    private var monitor: Any?
    private struct TaggedEvent {
        let index: Int
        let event: NSEvent
        let type: NSEvent.EventType
        let eventNumber: Int?
        let keyCode: UInt16?
        let timestamp: TimeInterval
    }

    private var tagged: [TaggedEvent] = []
    /// Index of the posted release that ends the pointer Back gesture, while it is awaited.
    private var pendingGestureRelease: Int?
    /// Set when the delivery of the posted release could not be established.
    private(set) var gestureUnresolved: String?
    /// Whether a responder is the owner control under test; set by the flow.
    var isOwnerResponder: ((NSResponder?) -> Bool)?
    private weak var lastResponderObject: NSResponder?
    private var lastWasOwner = false
    private var nextMouseNumber = 0x7E57_0000
    private var running = false

    init(fixture: any ResourceSlotsNativeHosting, state: ResourceSlotsReadingState, trace: ResourceSlotsNativeTrace, variant: String) {
        self.fixture = fixture
        self.state = state
        self.variant = variant
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
                                authorizedResponder: describe(state.focusReturnAuthorizedResponder)))
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

    /// An event is ours when it is the object we sent, or has the same type and event number
    /// (mouse), or the same type, key code and exact timestamp (key).
    private func taggedIndex(for event: NSEvent) -> Int? {
        let mouse = Self.isMouse(event.type)
        let match = tagged.first { entry in
            if entry.event === event { return true }
            guard entry.type == event.type else { return false }
            if mouse, let number = entry.eventNumber, number == event.eventNumber { return true }
            if mouse { return entry.timestamp == event.timestamp }
            return entry.keyCode == event.keyCode && entry.timestamp == event.timestamp
        }
        return match?.index
    }

    @discardableResult
    private func register(_ event: NSEvent, kind: String, target: String, backGesture: Bool) -> Int {
        sampleResponder(source: "pre-input")
        let tag = tagKey(event)
        let isKey = event.type == .keyDown || event.type == .keyUp
        let record = InputRecord(index: inputs.count, tag: tag, kind: kind,
                                 keyCode: isKey ? event.keyCode : nil,
                                 target: target, responderAtSend: lastResponder.summary, backGesture: backGesture,
                                 enqueuedAt: now, startSeq: next())
        tagged.append(TaggedEvent(index: record.index, event: event, type: event.type,
                                  eventNumber: Self.isMouse(event.type) ? event.eventNumber : nil,
                                  keyCode: isKey ? event.keyCode : nil, timestamp: event.timestamp))
        inputs.append(record)
        return record.index
    }

    private func finish(_ index: Int, release: String? = nil, endSeq: Int? = nil) {
        inputs[index].endSeq = endSeq ?? next()
        inputs[index].deliveredAt = now
        if let release { inputs[index].release = release }
        sampleResponder(source: "post-input")
    }

    private func observe(_ event: NSEvent) {
        guard event.window === fixture.window || event.windowNumber == fixture.window.windowNumber else { return }
        if let index = taggedIndex(for: event) {
            if inputs[index].release == nil {
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

    /// Tracking-safe click: the release is queued before the press is sent, so a tracking loop
    /// finds it. Gesture completion is stamped from evidence: at once when the release is gone
    /// without the monitor seeing it (consumed by tracking), after its dispatch when the monitor saw
    /// it, and "unresolved" (with the stranded release removed) when it is never dispatched.
    func click(at point: CGPoint, target: String) -> String {
        let window = fixture.window
        let base = nextMouseNumber
        nextMouseNumber += 2
        func mouse(_ type: NSEvent.EventType, _ number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
                               context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = mouse(.leftMouseDown, base), let up = mouse(.leftMouseUp, base + 1) else { return "events not created" }
        gestureCompleteSeq = nil
        gestureUnresolved = nil
        let upIndex = register(up, kind: "mouseUp (posted)", target: target, backGesture: true)
        pendingGestureRelease = upIndex
        NSApp.postEvent(up, atStart: true)
        let downIndex = register(down, kind: "mouseDown (sendEvent)", target: target, backGesture: true)
        window.sendEvent(down)
        // Taken before the queue peek, so the completion point is not moved by the peek.
        let returnedSeq = next()
        finish(downIndex, release: "sendEvent", endSeq: returnedSeq)
        if inputs[upIndex].release == nil, !releaseIsQueued(up) {
            // Gone from the queue and never seen by the monitor: a tracking loop consumed it.
            pendingGestureRelease = nil
            inputs[upIndex].release = "consumed by tracking"
            completeGesture(release: "mouse release consumed by tracking", at: returnedSeq)
            return "consumed by tracking"
        }
        let deadline = Date(timeIntervalSinceNow: 0.3)
        while gestureCompleteSeq == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        if gestureCompleteSeq != nil { return "dispatched" }
        pendingGestureRelease = nil
        if inputs[upIndex].release == nil {
            if releaseIsQueued(up) { _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) }
            inputs[upIndex].release = "unresolved"
        }
        gestureUnresolved = "the posted mouse release was not dispatched (release=\(inputs[upIndex].release ?? "none"))"
        stamp("back-gesture-unresolved", gestureUnresolved ?? "")
        return "unresolved"
    }

    private func releaseIsQueued(_ up: NSEvent) -> Bool {
        guard let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false) else { return false }
        return queued === up || (queued.eventNumber == up.eventNumber && queued.timestamp == up.timestamp)
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
            if isPostedRelease { return "during the release (\(input.kind) dispatched)" }
            if gesture.contains(where: { $0.release == "consumed by tracking" }) {
                return "during the press's tracking loop (release consumed; exact phase unresolved)"
            }
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

    // MARK: Reporting

    func timelineSummary(limit: Int = 60) -> String {
        var lines: [(Int, String)] = []
        for change in changes {
            let axText = change.accessibility.map { "ax=\($0.identifier ?? "-")|\($0.role ?? "-")|\($0.text ?? "-")" } ?? "ax=pending"
            lines.append((change.seq, "#\(change.seq) responder[\(change.source)] c\(change.cycle) "
                + "\(change.from.summary) -> \(change.to.summary) \(axText)"))
        }
        for input in inputs {
            lines.append((input.startSeq, "#\(input.startSeq) input \(input.kind) -> \(input.target) gesture=\(input.backGesture) "
                + "release=\(input.release ?? "-") end=#\(input.endSeq.map(String.init) ?? "-")"))
        }
        for entry in diagnostics {
            lines.append((entry.seq, "#\(entry.seq) diag \(entry.event) c\(entry.cycle)"))
        }
        for stamp in stamps { lines.append((stamp.seq, "#\(stamp.seq) \(stamp.text)")) }
        let sorted = lines.sorted { $0.0 < $1.0 }.map(\.1)
        return sorted.suffix(limit).joined(separator: " | ")
    }

    /// Writes the buffered timeline into the trace once the run is over.
    func flush(to trace: ResourceSlotsNativeTrace) {
        trace.mark("shell-evidence-summary", details: ["variant": variant, "contentHost": contentHostDescription,
                                                       "outsideInput": String(outsideInput.count),
                                                       "gestureRelease": gestureRelease ?? "none",
                                                       "limit": "local monitor cannot see events consumed inside nested tracking loops"])
        for cycle in cycles {
            trace.mark("shell-cycle", details: [
                "cycle": String(cycle.id), "authorizedSeq": String(cycle.authorizedSeq),
                "authorizedResponder": cycle.authorizedResponder.summary,
                "authorizedResponderID": cycle.authorizedResponder.identity.map { String(describing: $0) } ?? "nil",
                "requestToken": cycle.requestToken?.uuidString ?? "none", "requestSeq": cycle.requestSeq.map(String.init) ?? "none",
                "terminal": cycle.terminalEvent ?? "none", "terminalSeq": cycle.terminalSeq.map(String.init) ?? "none",
                "backFired": backFiredPhase(cycle)])
        }
        for change in changes {
            trace.mark("shell-responder-change", details: [
                "seq": String(change.seq), "cycle": String(change.cycle), "token": change.token?.uuidString ?? "none",
                "source": change.source, "from": change.from.summary, "to": change.to.summary,
                "toID": change.to.identity.map { String(describing: $0) } ?? "nil",
                "axIdentifier": change.accessibility?.identifier ?? "nil", "axRole": change.accessibility?.role ?? "nil",
                "axText": change.accessibility?.text ?? "nil"])
        }
        for input in inputs {
            trace.mark("shell-input", details: [
                "start": String(input.startSeq), "end": input.endSeq.map(String.init) ?? "none", "kind": input.kind,
                "target": input.target, "responderAtSend": input.responderAtSend, "backGesture": String(input.backGesture),
                "release": input.release ?? "none", "tag": input.tag,
                "enqueuedAt": String(format: "%.4f", input.enqueuedAt),
                "deliveredAt": input.deliveredAt.map { String(format: "%.4f", $0) } ?? "none"])
        }
        for entry in diagnostics {
            trace.mark("shell-diagnostic", details: ["seq": String(entry.seq), "event": entry.event, "cycle": String(entry.cycle),
                                                     "token": entry.token?.uuidString ?? "none"])
        }
        for item in stamps { trace.mark("shell-stamp", details: ["seq": String(item.seq), "text": item.text]) }
    }
}
