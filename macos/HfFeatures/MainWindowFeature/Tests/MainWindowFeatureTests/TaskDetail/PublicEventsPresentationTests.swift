import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor struct PublicEventsPresentationTests {
    private static func counts(toolCalls: Int = 0, edits: Int = 0, commands: Int = 0) -> ActivityCounts {
        var value = ActivityCounts()
        value.toolCalls = toolCalls
        value.edits = edits
        value.commands = commands
        return value
    }

    private static func frame(records: [String] = [], history: EventObservationHistory = .init(caughtUp: true, forwardDrained: true),
                              summary: ObservedActivitySummary = .init(state: .observed, counts: counts(), totalFiles: 0)) -> EventObservationFrame {
        EventObservationFrame(taskID: "fixture", scope: FeatureObservationFixture.scope, records: M05Fixtures.records(records),
                              history: history, summary: summary)
    }

    private static let failure = ToolError.refused(code: "fixture", message: "Fixture read failure")

    @Test func givenNoFrame_whenMade_thenLoadingRecordsWithCaptionAndNoActions() {
        // when
        let value = PublicEventsPresentation.make(from: nil)
        // then
        #expect(value.summary == .loadingRecords)
        #expect(value.note == nil)
        #expect(!value.isEmptyWindow)
        #expect(!value.showsLoadEarlier)
        #expect(value.showsRecordsCaption)
    }

    @Test func givenLoadingSummary_whenMade_thenLoadingSummaryAndNotEmpty() {
        // given
        let frame = Self.frame(history: .init(isLoading: true), summary: .init(state: .loading))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.summary == .loading)
        #expect(!value.isEmptyWindow)
        #expect(value.showsRecordsCaption)
    }

    @Test func givenObservedToolCalls_whenMade_thenCountsSummary() {
        // given
        let summary = ObservedActivitySummary(state: .observed, counts: Self.counts(toolCalls: 3, edits: 2, commands: 1), totalFiles: 2)
        let frame = Self.frame(records: ["tool_result"], summary: summary)
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.summary == .counts(toolCalls: 3, edits: 2, commands: 1))
        #expect(!value.isEmptyWindow)
        #expect(value.showsRecordsCaption)
    }

    @Test func givenRecordsWithZeroToolCalls_whenMade_thenNoToolCallsSummary() {
        // given
        let frame = Self.frame(records: ["notice"])
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.summary == .noToolCalls)
        #expect(!value.isEmptyWindow)
        #expect(value.showsRecordsCaption)
    }

    @Test func givenEmptyCurrentFullyReadWindow_whenMade_thenEmptyWindowWithoutSummaryOrRecordsCaption() {
        // given
        let frame = Self.frame()
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.isEmptyWindow)
        #expect(value.summary == .none)
        #expect(!value.showsRecordsCaption)
        #expect(value.note == nil)
        #expect(!value.showsLoadEarlier)
    }

    @Test(arguments: ["loading", "failure", "reconnecting", "sourceChangePending"])
    func givenEmptyWindowThatIsNotSettled_whenMade_thenNotEmptyWindow(scenario: String) {
        // given
        let history: EventObservationHistory = switch scenario {
        case "loading": .init(isLoading: true)
        case "failure": .init(failure: Self.failure)
        case "reconnecting": .init(currentness: .reconnecting)
        default: .init(currentness: .sourceChangePending)
        }
        // when
        let value = PublicEventsPresentation.make(from: Self.frame(history: history))
        // then
        #expect(!value.isEmptyWindow)
        #expect(value.summary != .none)
        #expect(value.showsRecordsCaption)
    }

    @Test func givenEmptyWindowWithRetryOffered_whenMade_thenNotEmptyWindow() {
        // given
        let frame = Self.frame(history: .init(availableActions: [.retryRead]))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(!value.isEmptyWindow)
        #expect(value.note == .historyUnavailable)
    }

    @Test func givenEmptyWindowWithUnavailableSummary_whenMade_thenNotEmptyWindow() {
        // given
        let frame = Self.frame(summary: .init(state: .unavailable, reasons: [.unavailable]))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(!value.isEmptyWindow)
        #expect(value.summary == .unavailable)
    }

    @Test func givenLoadEarlierOnly_whenMade_thenShowsLoadEarlierWithoutNote() {
        // given
        let frame = Self.frame(records: ["notice"], history: .init(hasOlder: true, availableActions: [.loadEarlier]))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.showsLoadEarlier)
        #expect(value.note == nil)
    }

    @Test func givenLoadEarlierAndRetryRead_whenMade_thenRetryWinsAndLoadEarlierIsHidden() {
        // given
        let frame = Self.frame(records: ["notice"], history: .init(hasOlder: true, availableActions: [.loadEarlier, .retryRead]))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(!value.showsLoadEarlier)
        #expect(value.note == .historyUnavailable)
    }

    @Test func givenRetryReadWithoutFailure_whenMade_thenNoteStillShown() {
        // given
        let frame = Self.frame(records: ["notice"], history: .init(availableActions: [.retryRead]))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(frame.history.failure == nil)
        #expect(value.note == .historyUnavailable)
    }

    @Test func givenFailureWithoutRetryRead_whenMade_thenNoNote() {
        // given
        let frame = Self.frame(records: ["notice"], history: .init(availableActions: [.loadEarlier], failure: Self.failure))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.note == nil)
        #expect(value.showsLoadEarlier)
    }

    @Test func givenCoverageOnlyUnavailableSummary_whenMade_thenUnavailableSummaryWithoutNote() {
        // given
        let frame = Self.frame(records: ["notice"], history: .init(reasons: [.gaps]),
                               summary: .init(state: .unavailable, reasons: [.unavailable]))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.summary == .unavailable)
        #expect(value.note == nil)
    }

    @Test func givenLimitedSummary_whenMade_thenUnavailableSummaryWithoutNote() {
        // given
        let frame = Self.frame(records: ["notice"], summary: .init(state: .limited, reasons: [.capacity]))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.summary == .unavailable)
        #expect(value.note == nil)
    }

    @Test func givenObservedSummaryWithoutCounts_whenMade_thenUnavailableSummary() {
        // given
        let frame = Self.frame(records: ["notice"], summary: .init(state: .observed, counts: nil))
        // when
        let value = PublicEventsPresentation.make(from: frame)
        // then
        #expect(value.summary == .unavailable)
    }
}
