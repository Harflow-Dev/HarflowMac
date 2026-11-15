import AppKit
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

/// Isolated component fixtures; these do not launch an engine or claim whole-window design fidelity.
@MainActor @Suite(.serialized) struct ObservationHostedTests {
    @Test(arguments: [ColorScheme.light, .dark], [1000.0, 1280.0])
    func givenObservationStates_whenHostedAtNativeWidths_thenRequestHistoryAndEventsStayBounded(scheme: ColorScheme, width: Double) async throws {
        // given
        _ = NSApplication.shared
        for scenario in ["loading", "partial", "integrity-failed", "unavailable", "reconnecting", "capacity", "events"] {
            let state = try requestState(scenario)
            let frame = observation(scenario)
            let recoveredEvent = TaskEvent(seq: 7, displayID: 0, observedAt: nil, sourceTimestamp: nil,
                kind: .assistantText(text: "Recovered evidence", messageID: nil, blockIndex: nil),
                rawLine: "Recovered evidence from a separately qualified transcript")
            let recovered = RecoveredTranscriptFrame(generation: UUID(), events: [recoveredEvent], items: Timeline.items(from: [recoveredEvent]))
            let surface = HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        StoredRequestView(state: state, read: { _ in }, copy: { _ in })
                        ObservationHistoryView(frame: frame, action: { _ in })
                        Text("Retained captured row").frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(24)
                }
                ScrollView { PublicEventsView(frame: frame, recovered: recovered, copy: { _ in }, action: { _ in }).padding(16) }
                    .frame(width: 300)
            }
.frame(width: width - 256, height: width == 1000 ? 620 : 800)
                .preferredColorScheme(scheme)
            let fixture = ObservationHost(surface, width: width - 256, height: width == 1000 ? 620 : 800, appearance: scheme)
            defer { fixture.close() }
            // when — an empty, fully read window drops the records caption in favour of the empty-window copy
            let sectionText = scenario == "capacity"
                ? "No rows in the available captured history" : "Public normalized events · bounded record window"
            await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.find(sectionText) != nil }
            try fixture.requireRequestedBounds()
            let heading = StoredRequestPresentation(state: state).heading
            if let disclosure = fixture.find(heading) { #expect(fixture.press(disclosure)) }
            await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.host.fittingSize.width > 0 }
            // then
            #expect(fixture.find(heading) != nil)
            #expect(fixture.find(sectionText) != nil)
            #expect(fixture.find("Recovered transcript") != nil)
            #expect(fixture.host.fittingSize.width <= width - 256 + 1)
            let visibleButtons = fixture.objects().filter { fixture.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue }
            for button in visibleButtons {
                guard let local = fixture.frame(button), local.width > 0 else { continue }
                #expect(local.minX >= -1 && local.maxX <= width - 256 + 1, "observation actions must not overflow the minimum-sized content region")
            }
            try await fixture.captureIfRequested(name: "\(scenario)-\(scheme == .dark ? "dark" : "light")-\(Int(width))")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenWrappingObservationActions_whenHosted_thenEightPointGapAndExplicitActionFocusArePreserved(scheme: ColorScheme) async throws {
        // given
        let frame = observation("events")
        var actions: [EventObservationAction] = []
        let fixture = ObservationHost(ObservationHistoryView(frame: frame, action: { actions.append($0) })
            .padding(24)
.preferredColorScheme(scheme), width: 396, height: 320, appearance: scheme)
        defer { fixture.close() }
        try await fixture.requireForeground()
        await waitUntil { fixture.find("Load earlier") != nil && fixture.find("Retry history read") != nil }
        #expect(abs(fixture.host.bounds.width - 396) <= 1 && abs(fixture.host.bounds.height - 320) <= 1)
        let earlier = try #require(fixture.find("Load earlier"))
        let retry = try #require(fixture.find("Retry history read"))
        // when / then — the first two actions fit together; native frames include the literal eight point gap.
        let first = try #require(fixture.frame(earlier))
        let second = try #require(fixture.frame(retry))
        #expect(abs(first.minY - second.minY) <= 1)
        #expect(abs(second.minX - first.maxX - 8) <= 1)
        #expect(fixture.press(earlier))
        await waitUntil { !actions.isEmpty }
        #expect(actions == [.loadEarlier])
        await waitUntil { fixture.objects().contains { fixture.isFocused($0) == true } }
        #expect(fixture.objects().contains { fixture.isFocused($0) == true },
                "explicit history action must leave an accessible focus owner")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenEventsPaneLoadEarlier_whenPressed_thenActionDispatchesOnceAndHeadingOwnsFocus(scheme: ColorScheme) async throws {
        // given
        let frame = M05Fixtures.frame(records: M05Fixtures.records(["notice"]),
            history: .init(hasOlder: true, forwardDrained: true, availableActions: [.loadEarlier]),
            summary: .init(state: .observed, counts: ActivityCounts(), totalFiles: 0))
        var actions: [EventObservationAction] = []
        let view = ScrollView { PublicEventsView(frame: frame, recovered: .init(), copy: { _ in }, action: { actions.append($0) }).padding(16) }
            .preferredColorScheme(scheme)
        let fixture = ObservationHost(view, width: 320, height: 420, appearance: scheme)
        defer { fixture.close() }
        try await fixture.requireForeground()
        await waitUntil { fixture.find(identifier: "task-events.load-earlier") != nil }
        let button = try #require(fixture.find(identifier: "task-events.load-earlier"))
        #expect(fixture.find(identifier: "task-events.retry-history-read") == nil)
        // when
        let before = fixture.window.firstResponder
        #expect(fixture.press(button))
        await waitUntil { !actions.isEmpty }
        // then
        #expect(actions == [.loadEarlier])
        await waitUntil { fixture.isHeadingFocused("Captured activity") }
        #expect(fixture.isHeadingFocused("Captured activity"),
                Comment(rawValue: "The Captured activity heading must own focus after Load earlier. "
                    + fixture.focusDiagnostics(expectedText: "Captured activity")))
        #expect(fixture.keyboardFocusMoved(from: before, button: button),
                "keyboard focus must move off the pressed button. \(fixture.responderDiagnostics(before))")
        #expect(actions == [.loadEarlier])
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenEventsPaneHistoryNote_whenRetryPressed_thenRetryReadDispatchesOnceAndLoadEarlierIsAbsent(scheme: ColorScheme) async throws {
        // given
        let frame = M05Fixtures.frame(records: M05Fixtures.records(["notice"]),
            history: .init(hasOlder: true, forwardDrained: true, availableActions: [.loadEarlier, .retryRead]),
            summary: .init(state: .observed, counts: ActivityCounts(), totalFiles: 0))
        var actions: [EventObservationAction] = []
        let view = ScrollView { PublicEventsView(frame: frame, recovered: .init(), copy: { _ in }, action: { actions.append($0) }).padding(16) }
            .preferredColorScheme(scheme)
        let fixture = ObservationHost(view, width: 320, height: 420, appearance: scheme)
        defer { fixture.close() }
        try await fixture.requireForeground()
        await waitUntil { fixture.find(identifier: "task-events.retry-history-read") != nil }
        let button = try #require(fixture.find(identifier: "task-events.retry-history-read"))
        #expect(fixture.find(identifier: "task-events.load-earlier") == nil)
        // when
        let before = fixture.window.firstResponder
        #expect(fixture.press(button))
        await waitUntil { !actions.isEmpty }
        // then
        #expect(actions == [.retryRead])
        await waitUntil { fixture.isHeadingFocused("Captured activity") }
        #expect(fixture.isHeadingFocused("Captured activity"),
                Comment(rawValue: "The Captured activity heading must own focus after Retry history read. "
                    + fixture.focusDiagnostics(expectedText: "Captured activity")))
        #expect(fixture.keyboardFocusMoved(from: before, button: button),
                "keyboard focus must move off the pressed button. \(fixture.responderDiagnostics(before))")
        #expect(actions == [.retryRead])
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenEventsPaneEarlierPageNote_whenRetryPressed_thenRetryReadDispatchesOnceAndNoteStaysBelowCaption(scheme: ColorScheme) async throws {
        // given
        let frame = M05Fixtures.frame(records: M05Fixtures.records(["notice"]),
            history: .init(hasOlder: true, forwardDrained: true, availableActions: [.loadEarlier, .retryRead], olderReadFailed: true),
            summary: .init(state: .observed, counts: ActivityCounts(), totalFiles: 0))
        var actions: [EventObservationAction] = []
        let view = ScrollView { PublicEventsView(frame: frame, recovered: .init(), copy: { _ in }, action: { actions.append($0) }).padding(16) }
            .preferredColorScheme(scheme)
        let fixture = ObservationHost(view, width: 320, height: 420, appearance: scheme)
        defer { fixture.close() }
        try await fixture.requireForeground()
        let title = "Earlier records couldn't be read"
        let caption = "Public normalized events · bounded record window"
        // The note's title and body are one combined accessibility element, so the title is matched as a prefix.
        func noteElement() -> NSObject? {
            fixture.objects().first { element in
                ["accessibilityLabel", "accessibilityValue"].contains { fixture.string(element, $0)?.hasPrefix(title) == true }
            }
        }
        await waitUntil { fixture.find(identifier: "task-events.retry-history-read") != nil && noteElement() != nil }
        let button = try #require(fixture.find(identifier: "task-events.retry-history-read"))
        #expect(fixture.find("Captured history unavailable") == nil)
        #expect(fixture.find(identifier: "task-events.load-earlier") == nil)
        // The heading is above the caption; the note is below both (window coordinates grow upward or downward alike).
        func isOrderedBelow() throws -> Bool {
            let headingFrame = try #require(fixture.find("Captured activity").flatMap(fixture.frame))
            let captionFrame = try #require(fixture.find(caption).flatMap(fixture.frame))
            let noteFrame = try #require(noteElement().flatMap(fixture.frame))
            let direction: CGFloat = headingFrame.midY > captionFrame.midY ? 1 : -1
            return (captionFrame.midY - noteFrame.midY) * direction > 0
        }
        #expect(try isOrderedBelow(), "the note follows the records caption before Retry is pressed")
        // when
        let before = fixture.window.firstResponder
        #expect(fixture.press(button))
        await waitUntil { !actions.isEmpty }
        // then
        #expect(actions == [.retryRead])
        await waitUntil { fixture.isHeadingFocused("Captured activity") }
        #expect(fixture.isHeadingFocused("Captured activity"),
                Comment(rawValue: "The Captured activity heading must own focus after Retry history read. "
                    + fixture.focusDiagnostics(expectedText: "Captured activity")))
        #expect(fixture.keyboardFocusMoved(from: before, button: button),
                "keyboard focus must move off the pressed button. \(fixture.responderDiagnostics(before))")
        #expect(try isOrderedBelow(), "the note stays below the caption after the dispatch")
        #expect(actions == [.retryRead])
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenPartialRequestReadMore_whenReplacementRemovesAction_thenFocusMovesToExpandedRequestText(scheme: ColorScheme) async throws {
        // given
        let partial = try requestState("partial")
        let fullText = "Replacement complete stored assignment"
        let complete = try #require(TaskPromptResult(raw: ["task_id": .string("fixture"), "title": .string("Fixture"),
            "prompt": .object(["state": .string("available"), "integrity": .string("verified"),
                "text": .string(fullText), "returned_bytes": .number(Double(fullText.utf8.count)),
                "total_bytes": .number(Double(fullText.utf8.count)), "truncated": .bool(false), "complete": .bool(true)])]))
        let model = RequestReplacementFixture(state: partial)
        let replacement = RequestReplacementView(model: model, complete: complete).preferredColorScheme(scheme)
        let fixture = ObservationHost(replacement, width: 396, height: 360, appearance: scheme)

        defer { fixture.close() }
        try await fixture.requireForeground()
        await waitUntil { fixture.find("Partial request") != nil }
        #expect(abs(fixture.host.bounds.width - 396) <= 1 && abs(fixture.host.bounds.height - 360) <= 1)
        let disclosure = try #require(fixture.find("Partial request"))
        #expect(fixture.press(disclosure))
        await waitUntil { fixture.find("Read more") != nil }
        let more = try #require(fixture.find("Read more"))
        // when
        #expect(fixture.press(more))
        await waitUntil { fixture.find("Copy original request") != nil && fixture.find("Read more") == nil }
        // then
        #expect(model.reads == [131072])
        #expect(fixture.find("Read more") == nil)
        await waitUntil {
            fixture.objects().contains { element in
                fixture.isFocused(element) == true
                    && ["accessibilityLabel", "accessibilityValue"].contains { fixture.string(element, $0) == fullText }
            }
        }
        #expect(fixture.objects().contains { element in
            fixture.isFocused(element) == true
                && ["accessibilityLabel", "accessibilityValue"].contains { fixture.string(element, $0) == fullText }
        }, Comment(rawValue: "The replacement text must own focus after Read more disappears. " + fixture.focusDiagnostics(expectedText: fullText)))
    }

    private func observation(_ scenario: String) -> EventObservationFrame {
        let history: EventObservationHistory = switch scenario {
        case "loading": .init(isLoading: true)
        case "reconnecting": .init(reasons: [.gaps], currentness: .reconnecting, availableActions: [.retryRead])
        case "capacity": .init(reasons: [.capacity], availableActions: [.rebaseWindow])
        case "events": .init(reasons: [.unknownKind], currentness: .sourceChangePending, availableActions: [.loadEarlier, .retryRead, .adoptCurrentSource])
        default: .init(reasons: [.gaps], availableActions: [.retryRead])
        }
        let records: [ObservedEventRecord] = scenario == "events" ? [7, 7, 6].enumerated().map { admission, sequence in
            let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.event"),
                "v": .number(1), "product_version": .string("0.0.8"), "seq": .number(Double(sequence)),
                "observed_at": .null, "kind": .string(admission == 1 ? "tool_result" : "future_kind"),
                "truncated": .bool(true), "oversized": .bool(false)]
            return ObservedEventRecord(id: .init(scope: FeatureObservationFixture.scope, admission: admission), record: TaskEventRecord(raw: raw)!)
        } : []
        return EventObservationFrame(taskID: "fixture", scope: FeatureObservationFixture.scope, records: records, history: history,
            summary: .init(state: scenario == "loading" ? .loading : scenario == "capacity" ? .observed : .unavailable,
                           counts: ActivityCounts(), totalFiles: 0))
    }

    private func requestState(_ scenario: String) throws -> TaskRequestReadState {
        if scenario == "loading" { return .loading(maxBytes: 65536) }
        let failed = scenario == "integrity-failed"
        let unavailable = scenario == "unavailable"
        let text = failed || unavailable ? nil : "  Stored assignment prefix.\nPreserve whitespace and provenance.\n"
        let prompt: [String: JSONValue] = ["state": .string(failed ? "integrity_failed" : unavailable ? "unavailable" : "available"),
            "integrity": .string(failed ? "failed" : unavailable ? "not_applicable" : "unverified"),
            "text": text.map(JSONValue.string) ?? .null, "returned_bytes": .number(Double(text?.utf8.count ?? 0)),
            "total_bytes": .null, "truncated": .bool(false), "complete": .bool(false)]
        let value = try #require(TaskPromptResult(raw: ["task_id": .string("fixture"), "title": .string("Fixture"), "prompt": .object(prompt)]))
        return .received(value, maxBytes: 65536)
    }
}

@Observable @MainActor
private final class RequestReplacementFixture {
    var state: TaskRequestReadState
    var reads: [Int] = []
    init(state: TaskRequestReadState) { self.state = state }
}

@MainActor
private struct RequestReplacementView: View {
    let model: RequestReplacementFixture
    let complete: TaskPromptResult
    var body: some View {
        StoredRequestView(state: model.state, read: { bound in
            model.reads.append(bound)
            model.state = .received(complete, maxBytes: bound)
        }, copy: { _ in }).padding(24)
    }
}

extension ObservationHost {
    /// Keyboard check: after the press the window's first responder is a different object than before, is not the pressed
    /// button's view, and lies inside the fixture. SwiftUI does not name the heading as the responder, so the accessibility
    /// check is the one that identifies it.
    func keyboardFocusMoved(from before: NSResponder?, button: NSObject) -> Bool {
        guard let after = window.firstResponder, after !== before, after !== (button as? NSResponder) else { return false }
        guard let view = after as? NSView else { return false }
        return view.isDescendant(of: host)
    }

    /// The responder before and after, for a failure message.
    func responderDiagnostics(_ before: NSResponder?) -> String {
        "before \(String(describing: before.map { type(of: $0) })), after \(String(describing: window.firstResponder.map { type(of: $0) }))"
    }

    /// Whether an element labelled `title` currently owns accessibility focus.
    func isHeadingFocused(_ title: String) -> Bool {
        objects().contains { string($0, "accessibilityLabel") == title && isFocused($0) == true }
    }
}
