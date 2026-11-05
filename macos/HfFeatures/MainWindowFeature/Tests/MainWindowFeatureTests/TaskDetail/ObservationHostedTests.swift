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
                ScrollView { PublicEventsView(frame: frame, recovered: recovered, copy: { _ in }).padding(16) }
                    .frame(width: 300)
            }
.frame(width: width - 256, height: width == 1000 ? 620 : 800)
                .preferredColorScheme(scheme)
            let fixture = ObservationHost(surface, width: width - 256, height: width == 1000 ? 620 : 800, appearance: scheme)
            defer { fixture.close() }
            // when
            await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.find("Public normalized events · bounded record window") != nil }
            try fixture.requireRequestedBounds()
            let heading = StoredRequestPresentation(state: state).heading
            if let disclosure = fixture.find(heading) { #expect(fixture.press(disclosure)) }
            await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return fixture.host.fittingSize.width > 0 }
            // then
            #expect(fixture.find(heading) != nil)
            #expect(fixture.find("Public normalized events · bounded record window") != nil)
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
