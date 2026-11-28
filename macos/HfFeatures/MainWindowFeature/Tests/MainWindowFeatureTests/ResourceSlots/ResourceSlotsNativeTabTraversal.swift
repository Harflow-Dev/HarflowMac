import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// Real Tab traversal support for the native header keyboard qualification. Tab is delivered
// as a paired keyDown/keyUp through `NSWindow.sendEvent`, exactly like the Space helper, and
// every step waits for an observable change in the responder or the focused accessibility
// element before it is trusted.

// MARK: - Results

struct ResourceSlotsTabTraversalResult {
    let entry: String
    var entryAvailable = false
    var reached = false
    var exhausted = false
    var ambiguous = false
    var steps: [String] = []

    var summary: String {
        "entry=\(entry), available=\(entryAvailable), reached=\(reached), exhausted=\(exhausted), ambiguous=\(ambiguous), steps=["
            + steps.joined(separator: "; ") + "]"
    }
}

private struct ResourceSlotsTabDestination: Hashable {
    let element: ObjectIdentifier
    let responder: ObjectIdentifier
}

// MARK: - Helpers

@MainActor
func resourceInteractionTab(_ window: NSWindow) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                           isARepeat: false, keyCode: 48) else { return }
        window.sendEvent(event)
    }
}

/// Waits up to three seconds for the predicate and reports whether it held.
@MainActor
func resourceInteractionWait(_ fixture: RedesignHost, until predicate: () -> Bool) async -> Bool {
    await waitUntil(timeout: 3) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()
        return predicate()
    }
    return predicate()
}

/// Proves the host delivers Tab through the key-view loop: a temporary, explicitly linked
/// pair of buttons inside a plain container view (never the window's theme frame) must pass
/// focus from the first to the second. The container is removed afterwards.
@MainActor
func resourceInteractionQualifyTabDelivery(_ fixture: RedesignHost) async -> Bool {
    let container = NSView(frame: CGRect(x: 12, y: 12, width: 260, height: 40))
    let first = NSButton(title: "Tab probe A", target: nil, action: nil)
    first.frame = CGRect(x: 0, y: 0, width: 120, height: 30)
    let second = NSButton(title: "Tab probe B", target: nil, action: nil)
    second.frame = CGRect(x: 130, y: 0, width: 120, height: 30)
    container.addSubview(first)
    container.addSubview(second)
    first.nextKeyView = second
    second.nextKeyView = first
    fixture.host.addSubview(container)
    var qualified = false
    if fixture.window.makeFirstResponder(first) {
        resourceInteractionTab(fixture.window)
        qualified = await resourceInteractionWait(fixture) { fixture.window.firstResponder === second }
    }
    container.removeFromSuperview()
    _ = fixture.window.makeFirstResponder(nil)
    let neutral = await resourceInteractionWait(fixture) { fixture.window.firstResponder === fixture.window }
    return qualified && neutral
}

@MainActor
private func resourceInteractionFocusableCount(_ fixture: RedesignHost) -> Int {
    var seen = Set<ObjectIdentifier>()
    let elements = fixture.descendants.flatMap { fixture.elements(in: $0) }.filter { seen.insert(ObjectIdentifier($0)).inserted }
    let roles: Set = ["AXButton", "AXDisclosureTriangle"]
    return elements.filter { roles.contains(fixture.string($0, "accessibilityRole") ?? "") }.count
}

private struct ResourceSlotsTabSnapshot {
    let responder: NSResponder?
    let element: NSObject?
    let identifier: String?
    let role: String?

    var responderName: String { responder.map { String(describing: type(of: $0)) } ?? "nil" }
    var label: String { "\(identifier ?? "nil")|\(role ?? "nil")" }
    var responderID: ObjectIdentifier? { responder.map(ObjectIdentifier.init) }
    var elementID: ObjectIdentifier? { element.map(ObjectIdentifier.init) }
    var retainedObjects: [AnyObject] { [responder as AnyObject?, element as AnyObject?].compactMap(\.self) }
}

@MainActor
private func resourceInteractionSnapshot(_ fixture: RedesignHost) -> ResourceSlotsTabSnapshot {
    let element = resourceSlotsNativeFocusedElement(fixture)
    return ResourceSlotsTabSnapshot(responder: fixture.window.firstResponder, element: element,
                                    identifier: element.flatMap { fixture.string($0, "accessibilityIdentifier") },
                                    role: element.flatMap { fixture.string($0, "accessibilityRole") })
}

/// Tabs from one entry point until the element with `target` as accessibility identifier is
/// focused, a confirmed destination repeats, or the budget runs out. The reported result is
/// scoped to this fixture and entry point.
@MainActor
func resourceInteractionTabToIdentifier(_ target: String, fixture: RedesignHost, entry: String,
                                        trace: ResourceSlotsNativeTrace) async -> ResourceSlotsTabTraversalResult {
    var result = ResourceSlotsTabTraversalResult(entry: entry)
    guard fixture.window.isKeyWindow, NSApp.isActive else {
        result.steps.append("host not key/active")
        return result
    }
    result.entryAvailable = await resourceInteractionEnter(entry, fixture: fixture, result: &result)
    trace.mark("header-tab-entry", details: ["entry": entry, "available": String(result.entryAvailable)])
    guard result.entryAvailable else { return result }
    await fixturelessSettlePump(5)

    let budget = max(12, 3 * resourceInteractionFocusableCount(fixture))
    // Strong references keep every recorded identity unique for the whole traversal.
    var retained: [AnyObject] = []
    defer { withExtendedLifetime(retained) {} }
    var destinations = Set<ResourceSlotsTabDestination>()
    var labels: [ObjectIdentifier: String] = [:]
    var previous = resourceInteractionSnapshot(fixture)
    retained.append(contentsOf: previous.retainedObjects)
    for step in 1 ... budget {
        let before = (previous.responderID, previous.elementID)
        resourceInteractionTab(fixture.window)
        let changed = await resourceInteractionWait(fixture) {
            let current = resourceInteractionSnapshot(fixture)
            return (current.responderID, current.elementID) != before
        }
        // Responder and focused element update independently; let both settle, then read them together.
        if changed { await fixturelessSettlePump(3) }
        let current = resourceInteractionSnapshot(fixture)
        retained.append(contentsOf: current.retainedObjects)
        // Only the final snapshot decides: focus that bounced back to where it started is not a move.
        let moved = (current.responderID, current.elementID) != before
        let state = moved ? "changed" : (changed ? "bounced" : "unchanged")
        result.steps.append("\(step):\(state):id=\(current.identifier ?? "nil"):role=\(current.role ?? "nil")"
            + ":responder=\(current.responderName)")
        trace.mark("header-tab-step", details: ["entry": entry, "step": String(step), "changed": state,
                                                "identifier": current.identifier ?? "nil", "role": current.role ?? "nil",
                                                "responder": current.responderName])
        defer { previous = current }
        // A step that did not end on a new focus target is never a destination, even when it
        // rests on the target.
        guard moved else {
            result.ambiguous = true
            continue
        }
        // Every destination check runs before the target is accepted.
        guard let focused = current.element, let currentResponder = current.responder,
              resourceInteractionValidate(current, previous: previous, labels: &labels) else {
            result.ambiguous = true
            continue
        }
        if current.identifier == target {
            result.reached = true
            return result
        }
        let destination = ResourceSlotsTabDestination(element: ObjectIdentifier(focused), responder: ObjectIdentifier(currentResponder))
        if !destinations.insert(destination).inserted {
            result.exhausted = true
            return result
        }
    }
    result.exhausted = true
    return result
}

// A destination is confirmed only when the observation is complete, the identity maps to a
// consistent identifier and role, and it is not a new identity repeating the previous label
// and responder (proxy churn).
@MainActor
private func resourceInteractionValidate(_ current: ResourceSlotsTabSnapshot, previous: ResourceSlotsTabSnapshot,
                                         labels: inout [ObjectIdentifier: String]) -> Bool {
    guard let element = current.element, current.responder != nil, current.identifier != nil else { return false }
    let identity = ObjectIdentifier(element)
    if let known = labels[identity], known != current.label { return false }
    if current.elementID != previous.elementID, current.label == previous.label,
       current.responderID == previous.responderID { return false }
    labels[identity] = current.label
    return true
}

@MainActor
private func resourceInteractionEnter(_ entry: String, fixture: RedesignHost,
                                      result: inout ResourceSlotsTabTraversalResult) async -> Bool {
    if entry == "host" {
        let accepted = fixture.window.makeFirstResponder(fixture.host)
        result.steps.append("entry responder=" + (fixture.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"))
        return accepted
    }
    _ = fixture.window.makeFirstResponder(nil)
    return await resourceInteractionWait(fixture) { fixture.window.firstResponder === fixture.window }
}

/// Qualifies Tab delivery, then tabs to the native resource header from the window-level entry
/// and, failing that, from the hosting view. Fails with a product finding only when Tab
/// qualified and every entry point was available, exhausted its budget and stayed unambiguous.
@MainActor
func resourceInteractionReachHeaderByTab(_ fixture: RedesignHost, model: ResourceSlotsInteractionModel,
                                         trace: ResourceSlotsNativeTrace) async throws {
    let target = "resource-slots-group-native-resource"
    let tabQualified = await resourceInteractionQualifyTabDelivery(fixture)
    trace.mark("header-tab-delivery-qualified", details: ["qualified": String(tabQualified)])
    try #require(tabQualified, Comment(rawValue: "Unresolved harness: Tab delivery through the key-view loop did not "
            + "qualify: " + resourceInteractionDiagnostic(fixture, model)))
    try resourceInteractionRequireActiveHost(fixture, model)
    var results = [await resourceInteractionTabToIdentifier(target, fixture: fixture, entry: "window", trace: trace)]
    if !results[0].reached {
        results.append(await resourceInteractionTabToIdentifier(target, fixture: fixture, entry: "host", trace: trace))
    }
    let reachedBy = results.first { $0.reached }
    let available = results.filter(\.entryAvailable)
    let isProductFinding = reachedBy == nil && available.count == results.count
        && results.allSatisfy { $0.exhausted && !$0.ambiguous }
    let verdict = isProductFinding
        ? "Header unreachable by Tab under Full Keyboard Access in this fixture and these entry points"
        : "Unresolved harness: the Tab traversal result is ambiguous or an entry point was unavailable"
    try #require(reachedBy != nil, Comment(rawValue: verdict + ": " + results.map(\.summary).joined(separator: " | ")
            + " :: " + resourceInteractionDiagnostic(fixture, model)))
    trace.mark("header-tab-reached", details: ["provesTabTraversal": "true", "entry": reachedBy?.entry ?? "nil"])
}
