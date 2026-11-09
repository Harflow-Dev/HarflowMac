//
//  TaskTopBarIntegratedHostedTests+Conditions.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Testing

// MARK: - Absence

/// A condition under which a chip must not be drawn, with the chips that must still be.
enum TopBarAbsence: CaseIterable, CustomTestStringConvertible, Sendable {
    case noContinuity, zeroNotices, noFreedom, pending

    var config: TopBarIntegratedFixture.Config {
        switch self {
        case .noContinuity: .init(width: 1600, notices: 3, continuity: false)
        case .zeroNotices: .init(width: 1600, notices: 0, continuity: false)
        case .noFreedom: .init(width: 1600, notices: 3, continuity: true, freedom: nil)
        case .pending: .init(width: 1600, status: "pending", notices: 3, continuity: false)
        }
    }

    var absent: [TopBarChip] {
        switch self {
        case .noContinuity: [.continuity]
        case .zeroNotices: [.continuity, .notices]
        case .noFreedom: [.access]
        case .pending: [.continuity, .access]
        }
    }

    var present: [TopBarChip] { TopBarChip.allCases.filter { !absent.contains($0) } }

    var testDescription: String {
        switch self {
        case .noContinuity: "no continuity"
        case .zeroNotices: "zero notices"
        case .noFreedom: "no freedom"
        case .pending: "pending task"
        }
    }
}

// MARK: - Conditions

extension TaskTopBarIntegratedHostedTests {

    /// The chip labels for a task that shows every chip: what an absent chip would have been called.
    private func fullLabels() -> [TopBarChip: String] {
        let content = TopBarFixtures.content(notices: 3, continuity: true, access: AccessLabel.text(freedom: "write_in_repo"))
        return Dictionary(uniqueKeysWithValues: TopBarChip.allCases.map { ($0, $0.label(for: content)) })
    }

    @Test(arguments: TopBarAbsence.allCases)
    func givenAConditionThatIsNotMet_whenTheBarIsRendered_thenItsChipIsAbsentFromTheToolbarAndTheOthersAreDrawn(
        absence: TopBarAbsence
    ) async throws {
        // given
        let fixture = await Fixture(absence.config)
        defer { fixture.close() }
        let content = try #require(fixture.content, "the task never published its top bar content")
        let expected = fixture.expectedItems(chips: absence.present, content: content)
        let labels = fullLabels()

        // when the chips that apply are drawn, so the toolbar has certainly settled
        await waitUntil(timeout: 8) { fixture.pump(); return fixture.problems(with: expected).isEmpty && fixture.principalItem != nil }
        for _ in 0 ..< 30 { fixture.pump() }

        // then every chip that applies is rendered and visible
        #expect(fixture.problems(with: expected).isEmpty, "\(fixture.problems(with: expected)); items \(fixture.itemIdentifiers)")

        // then each absent chip is gone from the rendered toolbar: no item of its identifier and no control carrying its label
        for chip in absence.absent {
            #expect(fixture.item(chip.identifier) == nil, "\(chip.identifier) is drawn although \(absence.testDescription)")
            if let label = labels[chip] {
                #expect(!fixture.toolbarRenders(label), "a control labelled \(label) is drawn although \(absence.testDescription)")
            }
        }
        if absence == .noFreedom || absence == .pending {
            let access = fixture.itemIdentifiers.filter { $0.hasSuffix("chip.access") }
            #expect(access.isEmpty, "an access chip item exists: \(access)")
        }
    }

    // MARK: - Resource return

    @Test func givenTheResourceReturn_whenOffered_thenItIsAVisibleToolbarItemAndAbsentOtherwise() async throws {
        // given
        let with = await Fixture(.init(width: 1280, resourceReturn: true))
        defer { with.close() }
        let without = await Fixture(.init(width: 1280))
        defer { without.close() }
        let label = "Back to resource slots"

        // when
        await waitUntil(timeout: 8) { with.pump(); without.pump(); return with.itemRendering(label) != nil && without.principalItem != nil }
        for _ in 0 ..< 30 { without.pump() }

        // then
        let item = try #require(with.itemRendering(label), "items \(with.itemIdentifiers)")
        #expect(with.isOnScreen(item), "the resource return is not visible with a positive frame")
        #expect(without.itemRendering(label) == nil, "the resource return is drawn although it was not offered")
    }

    // MARK: - Inline resource card

    @Test func givenARunningTaskHoldingHeavyBuild_whenRendered_thenTheInlineCardSitsAboveTheTranscript() async throws {
        // given the real VM derives the card from the task's phase_slots through the product's own resource context
        let fixture = await Fixture(.init(width: 1280, notices: 0, continuity: false, resourceHeld: true))
        defer { fixture.close() }
        let cardTitle = "Holding heavy-build"
        let cardMessage = "Capacity remains reserved for this task."

        // when the view model has produced the context, which is what the view draws from
        await waitUntil(timeout: 8) { fixture.pump(); return fixture.harness.sut.resourceContext != nil }
        let context = try #require(fixture.harness.sut.resourceContext, "the view model derived no resource context")
        #expect(context.title == cardTitle, "context title \(context.title)")
        #expect(context.message == cardMessage, "context message \(context.message)")

        // then the rendered card is found by exact text, whether SwiftUI exposes it as label, value or title
        await waitUntil(timeout: 8) {
            fixture.pump()
            return fixture.contentText(cardTitle) != nil && fixture.transcriptFrame != nil
        }
        let title = try #require(fixture.contentText(cardTitle), "no inline card; strings \(fixture.contentStrings)")
        #expect(fixture.contentText(cardMessage) != nil, "no card message; strings \(fixture.contentStrings)")
        let link = try #require(fixture.contentText("Open resource slots"), "no link to the resource slots; strings \(fixture.contentStrings)")
        let titleFrame = try #require(fixture.screenFrame(ofElement: title))
        let linkFrame = try #require(fixture.screenFrame(ofElement: link))
        #expect(titleFrame.width > 0 && titleFrame.height > 0 && linkFrame.width > 0 && linkFrame.height > 0)

        // then it is above the transcript (screen coordinates grow upward) and inside the window
        let transcript = try #require(fixture.transcriptFrame, "no activity transcript is mounted")
        #expect(titleFrame.minY >= transcript.maxY - 1, "the card (\(titleFrame)) is not above the transcript (\(transcript))")
        #expect(fixture.window.frame.insetBy(dx: -1, dy: -1).contains(titleFrame))

        // then the running task keeps its principal and Take over in the bar beside the card
        let published = try #require(fixture.content)
        let expected = fixture.expectedItems(chips: [.access], content: published)
        await waitUntil(timeout: 8) { fixture.pump(); return fixture.problems(with: expected).isEmpty }
        #expect(fixture.problems(with: expected).isEmpty, "\(fixture.problems(with: expected))")
    }

    @Test func givenARunningTaskWithoutAHeldResource_whenRendered_thenNoInlineCardIsDrawn() async throws {
        // given
        let fixture = await Fixture(.init(width: 1280, notices: 0, continuity: false))
        defer { fixture.close() }

        // when
        await waitUntil(timeout: 8) { fixture.pump(); return fixture.transcriptFrame != nil && fixture.principalItem != nil }
        for _ in 0 ..< 30 { fixture.pump() }

        // then
        #expect(fixture.harness.sut.resourceContext == nil, "the view model derived a resource context without a lease")
        #expect(fixture.resourceCardTitle("Holding heavy-build") == nil)
        #expect(fixture.contentText("Open resource slots") == nil)
    }
}
