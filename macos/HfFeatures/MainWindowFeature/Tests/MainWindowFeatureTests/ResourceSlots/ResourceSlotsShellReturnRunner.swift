import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// MARK: - Rig

struct ResourceSlotsBackLocation {
    /// Distinct containers (toolbar items, or one for in-content) rendering the Back button.
    var itemCount = 0
    /// All matching accessibility buttons, including nested duplicates.
    var rawCount = 0
    /// Window-coordinate frame of the first match.
    var frame: CGRect?
    /// The toolbar item's view, used to attribute a responder to the item.
    var container: NSView?
}

/// The responder transition each variant must show inside the Back action, before authorization
/// is recorded. Recorded for the control variant, never judged.
enum ResourceSlotsStartExpectation {
    /// The Back toolbar item's proxy resigns to the window.
    case toolbarProxyToWindow
    /// The window already holds focus: no transition.
    case noTransition
    /// A focused detail control's proxy resigns to the window.
    case detailControlToWindow
    /// Whatever the start shows.
    case recordedOnly

    var description: String {
        switch self {
        case .toolbarProxyToWindow: "KeyViewProxy@toolbar -> NSWindow"
        case .noTransition: "no transition (the window already holds focus)"
        case .detailControlToWindow: "KeyViewProxy (detail control) -> NSWindow"
        case .recordedOnly: "recorded only"
        }
    }

    var isJudged: Bool { self != .recordedOnly }

    func matches(_ change: ResourceSlotsShellEvidence.ResponderChange?) -> Bool {
        switch self {
        case .recordedOnly: return true
        case .noTransition: return change == nil
        case .toolbarProxyToWindow:
            guard let change else { return false }
            return change.from.className.contains("KeyViewProxy") && change.from.region == .toolbar && change.to.region == .window
        case .detailControlToWindow:
            guard let change else { return false }
            return change.from.className.contains("KeyViewProxy") && change.from.region != .toolbar && change.to.region == .window
        }
    }
}

/// Adapts one host (the shipping shell or the old in-content container) to the shared flow.
struct ResourceSlotsReturnRig {
    let fixture: any ResourceSlotsNativeHosting
    let state: ResourceSlotsReadingState
    let trace: ResourceSlotsNativeTrace
    let rowID: String
    let detailMarker: String
    let requiresToolbar: Bool
    let openedRows: @MainActor () -> [String]
    let isOnResourceSlots: @MainActor () -> Bool
    let backAvailable: @MainActor () -> Bool
    let returnCallbacks: @MainActor () -> Int
    let backLocation: @MainActor () -> ResourceSlotsBackLocation
    let extraFocusable: @MainActor () -> Int
    let expectedStart: ResourceSlotsStartExpectation
    var sidebarCollapsed = true
    /// A focusable control in the owner's detail that is focused before the pointer Back (P2f).
    var detailControlIdentifier: String?
    var ownerIdentifier: String { "resource-slots-owner-" + rowID }
}

enum ResourceSlotsBackGesture { case keyboard, pointer }

// MARK: - Helpers

@MainActor
func resourceSlotsShellWait(_ fixture: any ResourceSlotsNativeHosting, timeout: TimeInterval,
                            until predicate: @MainActor () -> Bool) async -> Bool {
    await waitUntil(timeout: timeout) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        fixture.contentRoot.layoutSubtreeIfNeeded()
        fixture.contentRoot.displayIfNeeded()
        return predicate()
    }
    return predicate()
}

/// Pumps the run loop for `seconds`, sampling the responder so every transition is logged.
@MainActor
private func resourceSlotsShellHold(_ evidence: ResourceSlotsShellEvidence, seconds: TimeInterval) {
    let started = evidence.now
    while evidence.now - started < seconds {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        evidence.sampleResponder(source: "stability")
    }
}

@MainActor
private func ownerControl(_ rig: ResourceSlotsReturnRig) -> ResourceSlotsOwnerButton.Control? {
    let controls = rig.fixture.descendants.compactMap { $0 as? ResourceSlotsOwnerButton.Control }
    return controls.first { $0.accessibilityIdentifier() == rig.ownerIdentifier }
}

@MainActor
private func isBack(_ snapshot: ResourceSlotsTabSnapshot, rig: ResourceSlotsReturnRig) -> Bool {
    if snapshot.text == ResourceSlotsShellFixture.backTitle { return true }
    let location = rig.backLocation()
    if let container = location.container, let view = snapshot.responder as? NSView, view.isDescendant(of: container) { return true }
    if let frame = location.frame, let element = snapshot.element, let focused = rig.fixture.frame(element),
       frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: focused.midX, y: focused.midY)) { return true }
    return false
}

// MARK: - Flow

/// Runs one variant: qualify, Tab to the owner, open it by Space, then press Back by keyboard or
/// a tracking-safe click, and classify. Never resets the responder after the qualification.
@MainActor
// swiftlint:disable:next function_body_length cyclomatic_complexity
func resourceSlotsShellRun(_ name: String, gesture: ResourceSlotsBackGesture, rig: ResourceSlotsReturnRig,
                           evidence: ResourceSlotsShellEvidence) async -> ResourceSlotsShellVerdict {
    let fixture = rig.fixture
    let trace = rig.trace
    var observation = ResourceSlotsShellObservation()
    defer {
        evidence.stop()
        evidence.flush(to: trace)
    }
    func unexecuted(_ reason: String) -> ResourceSlotsShellVerdict {
        trace.mark("shell-unexecuted", details: ["variant": name, "reason": reason])
        observation.unexecuted = reason
        observation.outsideInput = evidence.outsideInput
        return resourceSlotsShellClassify(observation)
    }
    trace.mark("shell-mode", details: [
        "variant": name, "gesture": String(describing: gesture), "sidebarCollapsed": String(rig.sidebarCollapsed),
        "detailControl": rig.detailControlIdentifier ?? "none",
        "axEnhancedUserInterface": String(describing: NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))),
        "fullKeyboardAccess": String(NSApp.isFullKeyboardAccessEnabled)])

    // Qualification before activation.
    guard fixture.window.isKeyWindow, NSApp.isActive else { return unexecuted("window is not key or the app is not active") }
    guard rig.state.focusReturnHostWindow === fixture.window else {
        return unexecuted("the reading state's hosting window is not the fixture window")
    }
    if rig.requiresToolbar, !M04ToolbarEvidence.isPopulated(fixture.window) { return unexecuted("toolbar is not populated") }
    guard await resourceInteractionQualifyTabDelivery(fixture, input: evidence) else { return unexecuted("Tab delivery did not qualify") }
    guard fixture.element(rig.ownerIdentifier) != nil, let owner = ownerControl(rig) else {
        return unexecuted("owner row \(rig.ownerIdentifier) not found by accessibility identity")
    }
    evidence.chooseContentHost(owner: owner)
    evidence.isOwnerResponder = { ($0 as? ResourceSlotsOwnerButton.Control)?.accessibilityIdentifier() == rig.ownerIdentifier }
    trace.mark("shell-content-host", details: ["description": evidence.contentHostDescription])
    evidence.start()

    // Keyboard to the owner, then activate it.
    let toOwner = await resourceInteractionTabToIdentifier(rig.ownerIdentifier, fixture: fixture, entry: "current",
                                                           trace: trace, input: evidence)
    guard toOwner.reached else { return unexecuted("Tab did not reach the owner row: " + toOwner.summary) }
    evidence.sendSpace(target: "owner " + rig.rowID, backGesture: false)
    let shown = await resourceSlotsShellWait(fixture, timeout: 3) {
        rig.openedRows().count == 1 && !rig.isOnResourceSlots() && rig.backAvailable() && fixture.element(rig.detailMarker) != nil
    }
    guard shown else { return unexecuted("the owner detail never appeared (marker \(rig.detailMarker))") }
    await fixturelessSettlePump(5)

    // The detail control that holds keyboard focus when a pointer Back leaves the detail (P2f).
    if let identifier = rig.detailControlIdentifier {
        guard fixture.element(identifier) != nil else { return unexecuted("detail control \(identifier) not found by accessibility identity") }
        let toDetail = await resourceInteractionTabToIdentifier(identifier, fixture: fixture, entry: "current", trace: trace,
                                                                input: evidence)
        guard toDetail.reached else { return unexecuted("Tab did not reach the detail control: " + toDetail.summary) }
        let focused = resourceInteractionSnapshot(fixture)
        guard focused.identifier == identifier else {
            return unexecuted("the detail control is not focused (focused: \(focused.label), responder \(focused.responderName))")
        }
        trace.mark("shell-detail-control-focused", details: ["identifier": identifier, "responder": focused.responderName])
    }

    // Staged qualification after activation.
    var location = rig.backLocation()
    trace.mark("shell-back-location", details: ["items": String(location.itemCount), "raw": String(location.rawCount),
                                               "frame": String(describing: location.frame)])
    guard location.itemCount == 1 else {
        return unexecuted("expected exactly one Back button, found \(location.itemCount) (raw \(location.rawCount))")
    }

    // Reach Back.
    var clickPoint: CGPoint?
    switch gesture {
    case .keyboard:
        let budget = 3 * (resourceInteractionFocusableCount(fixture) + rig.extraFocusable()) + 12
        let target = ResourceSlotsTabTarget.predicate(ResourceSlotsShellFixture.backTitle) { isBack($0, rig: rig) }
        let toBack = await resourceInteractionTabToTarget(target, fixture: fixture, entry: "current", trace: trace,
                                                          input: evidence, budgetOverride: budget)
        guard toBack.reached else { return unexecuted("Back is not keyboard-reachable: " + toBack.summary) }
    case .pointer:
        location = rig.backLocation()
        guard let frame = location.frame, frame.width > 0, frame.height > 0 else { return unexecuted("Back has no usable frame") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let screenPoint = fixture.window.convertPoint(toScreen: point)
        guard fixture.window.frame.insetBy(dx: -1, dy: -1).contains(screenPoint) else {
            return unexecuted("click point \(point) maps outside the window (screen \(screenPoint))")
        }
        let hit = fixture.window.contentView?.superview?.hitTest(point)
        let chain = sequence(first: hit, next: { $0?.superview }).compactMap(\.self).map { String(describing: type(of: $0)) }
        trace.mark("shell-click-hit", details: ["point": String(describing: point), "chain": chain.prefix(8).joined(separator: ">")])
        guard let hit, ResourceSlotsShellEvidence.isInToolbar(hit) else {
            return unexecuted("click point does not hit a toolbar view (hit \(chain.first ?? "nil"))")
        }
        clickPoint = point
    }

    // Back gesture.
    let before = (authorized: evidence.count("focus-authorized"), request: evidence.count("focus-request"),
                  restored: evidence.count("focus-restored"), moved: evidence.count("focus-user-moved"),
                  cancel: evidence.count("user-cancel"), budget: evidence.count("focus-budget-exhausted"))
    let callbacksBefore = rig.returnCallbacks()
    let cyclesBefore = evidence.cycles.count
    evidence.stamp("back-gesture-begin", String(describing: gesture))
    let beginSeq = evidence.seq
    switch gesture {
    case .keyboard: evidence.sendSpace(target: "Back (keyboard)", backGesture: true)
    case .pointer:
        let release = evidence.click(at: clickPoint ?? .zero, target: "Back (click)")
        trace.mark("shell-click-release", details: ["release": release])
    }
    let authorized = await resourceSlotsShellWait(fixture, timeout: 1) { evidence.cycles.count > cyclesBefore }
    guard authorized else { return unexecuted("the Back gesture did not authorize a focus return") }
    if rig.returnCallbacks() != callbacksBefore + 1 {
        return unexecuted("expected exactly one Back activation, saw \(rig.returnCallbacks() - callbacksBefore)")
    }
    guard let cycle = evidence.currentCycle else { return unexecuted("no return cycle recorded") }
    trace.mark("shell-back-fired", details: ["phase": evidence.backFiredPhase(cycle)])

    // The terminal diagnostic and the owner acquisition share one absolute deadline from authorization.
    let deadline = cycle.authorizedAt + 3
    func ownerNow() -> Bool { evidence.isOwnerResponder?(fixture.window.firstResponder) == true }
    _ = await resourceSlotsShellWait(fixture, timeout: max(0.05, deadline - evidence.now)) {
        evidence.sampleResponder(source: "wait")
        let terminal = evidence.currentCycle?.terminalEvent
        return terminal != nil && (terminal != "focus-restored" || ownerNow())
    }
    evidence.sampleResponder(source: "deadline")
    var oracle = ResourceSlotsShellObservation.Oracle()
    let terminal = evidence.currentCycle?.terminalEvent
    // Acquisition and stability are one interval: the first acquisition within the deadline, then no
    // departure from the owner for 0.5 s from that acquisition.
    let acquired = evidence.ownerAcquiredAt(since: cycle.authorizedAt, until: deadline)
    oracle.ownerIsFirstResponder = ownerNow() && acquired != nil
    if let acquired, oracle.ownerIsFirstResponder {
        resourceSlotsShellHold(evidence, seconds: max(0, acquired + 0.5 - evidence.now))
        oracle.stable = ownerNow() && !evidence.leftOwner(since: acquired, until: acquired + 0.5)
    }
    if evidence.currentCycle?.terminalEvent == nil {
        trace.mark("shell-no-terminal", details: ["note": "no terminal diagnostic by the deadline; the cancel and contamination search ran to the deadline"])
    }

    // Counts and the input window are taken before the reopen Space.
    guard let final = evidence.currentCycle else { return unexecuted("no return cycle recorded") }
    observation.outsideInput = evidence.outsideInput
    observation.gestureUnresolved = evidence.gestureUnresolved
    observation.authorized = evidence.count("focus-authorized") - before.authorized
    observation.requests = evidence.count("focus-request") - before.request
    observation.restored = evidence.count("focus-restored") - before.restored
    observation.userMoved = evidence.count("focus-user-moved") - before.moved
    observation.userCancel = evidence.count("user-cancel") - before.cancel
    observation.budget = evidence.count("focus-budget-exhausted") - before.budget
    observation.gestureCompleteSeq = evidence.gestureCompleteSeq
    let limit = final.terminalSeq ?? (evidence.seq + 1)
    let cancelEvents: Set = ["focus-user-moved", "user-cancel"]
    let cancel = evidence.diagnostics.first { $0.seq > final.authorizedSeq && $0.seq <= limit && cancelEvents.contains($0.event) }
    observation.cancelSeq = cancel?.seq
    observation.independentInputs = evidence.independentInputs(after: final.authorizedSeq, before: limit)
    let transitions = evidence.transitions(after: final.authorizedSeq, before: observation.cancelSeq ?? limit)
    observation.transitionSummary = transitions.map { "\($0.from.summary) -> \($0.to.summary)" }.joined(separator: "; ")
    observation.priorLeakedEvent = evidence.priorLeakedEvent
    // The starting transition is the last one inside the Back action, before authorization is recorded.
    let start = evidence.changes.last { $0.seq > beginSeq && $0.seq < final.authorizedSeq }
    let startSummary = start.map { "\($0.from.summary) -> \($0.to.summary)" } ?? "no transition"
    let startMatches = rig.expectedStart.matches(start)
    evidence.startOracleLine = "expected \(rig.expectedStart.description); observed \(startSummary); resign=\(final.resign) "
        + "kind=\(final.authorizedKind); "
        + (rig.expectedStart.isJudged ? (startMatches ? "matches" : "differs") : "recorded only")
    trace.mark("shell-start-oracle", details: ["variant": name, "expected": rig.expectedStart.description, "observed": startSummary,
                                               "result": startMatches ? "matches" : "differs"])
    if rig.expectedStart.isJudged, !startMatches {
        observation.startMismatch = "expected \(rig.expectedStart.description), observed \(startSummary)"
    }
    observation.proxyToProxy = transitions.filter {
        $0.from.className.contains("KeyViewProxy") && $0.to.className.contains("KeyViewProxy")
    }
.map { "\($0.from.summary) -> \($0.to.summary)" }
    observation.subtype = resourceSlotsShellSubtype(observation, transitions: transitions, authorized: final.authorizedResponder)

    if oracle.stable, terminal == "focus-restored" {
        oracle.reopenAttempted = true
        let opened = rig.openedRows().count
        evidence.sendSpace(target: "owner " + rig.rowID + " (reopen)", backGesture: false)
        oracle.reopenedSameRow = await resourceSlotsShellWait(fixture, timeout: 3) {
            rig.openedRows().count == opened + 1 && rig.openedRows().last == rig.rowID
        }
    }
    observation.oracle = oracle
    // Untagged input seen during the reopen wait still invalidates the result.
    observation.outsideInput = evidence.outsideInput
    let verdict = resourceSlotsShellClassify(observation)
    trace.mark("shell-verdict", details: [
        "variant": name, "verdict": verdict.headline, "authorizedResponder": final.authorizedResponder.summary,
        "resign": final.resign, "authorizedKind": final.authorizedKind,
        "terminal": final.terminalEvent ?? "none", "backFired": evidence.backFiredPhase(final),
        "startOracle": evidence.startOracleLine ?? "none", "priorLeakedEvent": evidence.priorLeakedEvent ?? "none",
        "counts": "auth=\(observation.authorized) request=\(observation.requests) restored=\(observation.restored) "
            + "moved=\(observation.userMoved) cancel=\(observation.userCancel) budget=\(observation.budget)"])
    return verdict
}

/// One line for the guarded runner's output; the finding name appears in every failure.
@MainActor
func resourceSlotsShellReport(_ name: String, _ verdict: ResourceSlotsShellVerdict, evidence: ResourceSlotsShellEvidence,
                              recordsIssue: Bool) {
    print("RESOURCE_SLOTS_SHELL variant=\(name) verdict=\(verdict.headline) start=[\(evidence.startOracleLine ?? "not evaluated")]")
    guard recordsIssue, !verdict.isPass else { return }
    Issue.record(Comment(rawValue: "F-RS-FKA-RETURN \(name): \(verdict.headline) :: contentHost=\(evidence.contentHostDescription) :: "
        + evidence.timelineSummary()))
}

/// Descriptive wording only: what the log showed, never a code path or a mechanism.
@MainActor
private func resourceSlotsShellSubtype(_ observation: ResourceSlotsShellObservation,
                                       transitions: [ResourceSlotsShellEvidence.ResponderChange],
                                       authorized: ResourceSlotsShellEvidence.ResponderRecord) -> String {
    let last = transitions.last.map { "\($0.from.summary) -> \($0.to.summary)" } ?? "none"
    if observation.userCancel > 0, observation.userMoved == 0 {
        return "user-cancel diagnostic observed; last observed transition: " + last
    }
    guard let only = transitions.first else { return "no responder transition observed in the log" }
    guard transitions.count == 1 else { return "\(transitions.count) transitions observed; last observed transition: " + last }
    let sampled = only.accessibility.map { $0.identifier != nil || $0.role != nil } ?? false
    if only.from.region == .toolbar, only.to.region == .content, sampled {
        return "toolbar-to-content transition observed (\(last))"
    }
    return "single transition observed: " + last
}
