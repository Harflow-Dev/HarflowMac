import AppKit
import Foundation
@testable import MainWindowFeature

// MARK: - ResourceSlotsShellEvidence + Release

extension ResourceSlotsShellEvidence {
    /// Tracking-safe click: the release is queued before the press is sent, so a tracking loop
    /// finds it. Only a monitor-observed release is resolved: gesture completion is stamped after
    /// its dispatch, from the run loop. Anything else is "unresolved". Whether the release was
    /// consumed inside a tracking loop is never claimed. A matched release still queued after the press is
    /// dispatched through NSApp.sendEvent; one still queued after the wait is removed and reported
    /// unresolved; a queue change during dispatch makes the run unresolved. An unobserved release that is
    /// not in the queue and was not dispatched by the harness may be a leaked event.
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
        queueDisturbed = false
        var harnessDispatched = false
        let upIndex = register(up, kind: "mouseUp (posted)", target: target, backGesture: true)
        pendingGestureRelease = upIndex
        NSApp.postEvent(up, atStart: true)
        let downIndex = register(down, kind: "mouseDown (sendEvent)", target: target, backGesture: true)
        window.sendEvent(down)
        let returnedSeq = next()
        finish(downIndex, release: "sendEvent", endSeq: returnedSeq)
        stamp("release-after-press", queuedDescription(upIndex))
        // A control without a tracking loop leaves the release queued, and `RunLoop` does not dispatch
        // application events. Dispatch exactly our own matched release through the application, so the
        // local monitors observe it.
        if inputs[upIndex].release == nil, let (queued, clause) = dequeueMatchedRelease(upIndex) {
            log("harness dispatching #\(upIndex) (matched by \(clause)): " + fields(queued))
            harnessDispatched = true
            NSApp.sendEvent(queued)
            if inputs[upIndex].release == "dispatched" {
                inputs[upIndex].release = "dispatched by harness (release left queued after press)"
            }
        }
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while gestureCompleteSeq == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        if queueDisturbed {
            pendingGestureRelease = nil
            finalizeReleaseCustody(upIndex, harnessDispatched: harnessDispatched)
            gestureUnresolved = "queue changed during release dispatch"
            stamp("back-gesture-unresolved", gestureUnresolved ?? "")
            return "unresolved"
        }
        if gestureCompleteSeq != nil { return "dispatched" }
        pendingGestureRelease = nil
        resolveUnobservedRelease(upIndex, harnessDispatched: harnessDispatched)
        return "unresolved"
    }

    /// Records why the release was not resolved after the wait, and removes it if it is still queued.
    func resolveUnobservedRelease(_ upIndex: Int, harnessDispatched: Bool) {
        var state = "the monitor observed the release but completion was not stamped"
        var disturbedDetail: String?
        if inputs[upIndex].release == nil {
            if harnessDispatched {
                inputs[upIndex].release = "unresolved (dispatched by harness, unobserved by monitor)"
                state = "the harness dispatched the release but the monitor did not observe it"
            } else if let (_, clause) = dequeueMatchedRelease(upIndex) {
                inputs[upIndex].release = "unresolved (queued, removed)"
                state = "the release stayed queued (matched by \(clause)) and was removed"
            } else if queueDisturbed {
                finalizeReleaseCustody(upIndex, harnessDispatched: false)
                disturbedDetail = "queue changed during release removal"
            } else {
                inputs[upIndex].release = "unresolved (not observed, not in the queue)"
                state = "the release was not observed and not found in the queue: possible leaked event"
                Self.possibleLeakedEvent = "variant \(variant): the release posted at seq #\(inputs[upIndex].startSeq) "
                    + "was neither observed nor found in the queue"
            }
        }
        gestureUnresolved = disturbedDetail ?? "release unobserved; delivery unresolved (\(state))"
        stamp("back-gesture-unresolved", gestureUnresolved ?? "")
    }

    /// Accounts for the release after a queue disturbance. A release the monitor has not observed and the
    /// harness has not dispatched is removed if it is still positively matched in the queue; otherwise its
    /// location is unknown and the run is marked as a possible leaked event.
    func finalizeReleaseCustody(_ index: Int, harnessDispatched: Bool) {
        guard inputs[index].release == nil, !harnessDispatched else { return }
        if dequeueMatchedRelease(index) != nil {
            inputs[index].release = "unresolved (queued, removed after queue disturbance)"
            return
        }
        inputs[index].release = "unresolved (not observed, location unknown after queue disturbance)"
        log("release location unknown after queue disturbance: #\(index)")
        Self.possibleLeakedEvent = "variant \(variant): the release posted at seq #\(inputs[index].startSeq) "
            + "was neither observed nor found in the queue after a queue disturbance"
    }

    /// Removes and returns the first queued left-mouse-up only if it is the tagged event at `index`.
    /// A dequeued event that is not the one just matched is posted back and `nil` is returned.
    func dequeueMatchedRelease(_ index: Int) -> (event: NSEvent, clause: String)? {
        guard let entry = tagged.first(where: { $0.index == index }),
              let peeked = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
              let clause = matchClause(entry, peeked),
              let removed = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
        else { return nil }
        guard removed === peeked || matchClause(entry, removed) != nil else {
            NSApp.postEvent(removed, atStart: true)
            queueDisturbed = true
            log("release-queue-disturbed: peeked " + fields(peeked) + "; dequeued " + fields(removed))
            return nil
        }
        return (removed, clause)
    }

    /// The clause by which the first queued left-mouse-up is the tagged event at `index`, or `nil`.
    func queuedClause(_ index: Int) -> String? {
        guard let entry = tagged.first(where: { $0.index == index }),
              let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false)
        else { return nil }
        return matchClause(entry, queued)
    }

    func queuedDescription(_ index: Int) -> String {
        guard let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false) else {
            return "no left-mouse-up queued; release \(inputs[index].release ?? "not yet observed")"
        }
        let clause = queuedClause(index).map { "matched by \($0)" } ?? "not matched"
        return "queued (\(clause)): " + fields(queued)
    }
}
