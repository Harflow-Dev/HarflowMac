import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - CallerApprovalPinnedBarTests

@MainActor @Suite(.serialized)
struct CallerApprovalPinnedBarTests {
    private func controller(for requests: [CallerApprovalRequest], supportsCaller: Bool = false)
        async -> (CallerApprovalController, CallerApprovalCaptureFake) {
        let fake = CallerApprovalCaptureFake(requests: requests)
        fake.supportsCallerResponses = supportsCaller
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: "task-capture", workflowRunID: nil)
        return (controller, fake)
    }

    @Test
    func givenTwoPendingRequests_whenSelectingBars_thenTheyFollowCardOrder() async {
        // given
        let first = approvalCaptureRequest(owner: "monitor", id: "req-a", command: "ls", createdAt: 10)
        let second = approvalCaptureRequest(owner: "monitor", id: "req-b", command: "pwd", createdAt: 20)
        let (controller, _) = await controller(for: [second, first])
        // when
        let bars = CallerApprovalPresentation.pinnedBars(controller.cards)
        // then
        #expect(bars.map(\.id) == ["req-a", "req-b"])
        #expect(controller.cards.map(\.id) == bars.map(\.id))
    }

    @Test
    func givenTwoPendingRequests_whenTheFirstSettles_thenItsBarGoesAndTheSecondRemains() async {
        // given
        let first = approvalCaptureRequest(owner: "monitor", id: "req-a", command: "ls", createdAt: 10)
        let second = approvalCaptureRequest(owner: "monitor", id: "req-b", command: "pwd", createdAt: 20)
        let (controller, fake) = await controller(for: [first, second])
        #expect(CallerApprovalPresentation.pinnedBars(controller.cards).map(\.id) == ["req-a", "req-b"])
        // when
        fake.requests = [approvalCaptureRequest(owner: "monitor", id: "req-a", command: "ls", disposition: "decided", createdAt: 10), second]
        await controller.refresh()
        // then
        #expect(CallerApprovalPresentation.pinnedBars(controller.cards).map(\.id) == ["req-b"])
        #expect(controller.cards.first { $0.id == "req-a" }?.awaitingDecision == false)
        #expect(controller.cards.contains { $0.awaitingDecision })
    }

    @Test
    func givenReadOnlyCallerRequest_whenSelectingBars_thenNoBarIsOfferedButItStillAwaitsADecision() async {
        // given: a caller-owned request the engine cannot answer from here
        let (controller, _) = await controller(for: [approvalCaptureRequest(owner: "caller", id: "req-c")])
        // when
        let card = controller.cards.first
        // then
        #expect(CallerApprovalPresentation.pinnedBars(controller.cards).isEmpty)
        #expect(card?.pending == true)
        #expect(card?.showsDecisionControls == false)
        #expect(card?.awaitingDecision == true)
    }

    @Test
    func givenBlockedCard_whenReadingTheModel_thenItStillAwaitsADecisionWithoutABar() async {
        // given: a response the fake does not confirm leaves the card blocked with its notice
        let request = approvalCaptureRequest(owner: "monitor", id: "req-blocked")
        let (controller, fake) = await controller(for: [request])
        await controller.inspect(request)
        #expect(CallerApprovalPresentation.pinnedBars(controller.cards).map(\.id) == ["req-blocked"])
        // when
        await controller.respond("approve")
        // then
        let card = controller.cards.first
        #expect(fake.responses == [CallerApprovalCaptureFake.Response(requestID: "req-blocked", decision: "approve")])
        #expect(card?.pending == false)
        #expect(card?.awaitingDecision == true)
        #expect(card?.notice != nil)
        #expect(CallerApprovalPresentation.pinnedBars(controller.cards).isEmpty)
    }

    @Test
    func givenSettledRequest_whenReadingTheModel_thenItDoesNotAwaitADecision() async {
        // given
        let settled = approvalCaptureRequest(owner: "monitor", id: "req-done", disposition: "decided")
        let (controller, _) = await controller(for: [settled])
        // when
        let card = controller.cards.first
        // then
        #expect(card?.awaitingDecision == false)
        #expect(CallerApprovalPresentation.pinnedBars(controller.cards).isEmpty)
    }

    @Test
    func givenToggledBlockedCard_whenItIsRebuilt_thenAwaitingDecisionSurvives() async {
        // given
        let request = approvalCaptureRequest(owner: "monitor", id: "req-blocked")
        let (controller, _) = await controller(for: [request])
        await controller.inspect(request)
        await controller.respond("approve")
        #expect(controller.cards.first?.awaitingDecision == true)
        // when
        controller.toggle("req-blocked")
        // then
        #expect(controller.cards.first?.awaitingDecision == true)
    }

    @Test
    func givenDemandPreference_whenReducingColumns_thenTheLargestWins() {
        // given
        var value = CallerApprovalDemand()
        // when
        CallerApprovalDemandKey.reduce(value: &value) { CallerApprovalDemand(natural: 120, awaitingDecision: true) }
        CallerApprovalDemandKey.reduce(value: &value) { CallerApprovalDemand(natural: 80, awaitingDecision: false) }
        // then
        #expect(value == CallerApprovalDemand(natural: 120, awaitingDecision: true))
        #expect(value.reserved == 120)
        #expect(CallerApprovalDemand(natural: 300, awaitingDecision: false).reserved == 0)
    }

    @Test
    func givenCommandsDifferingOnlyAtTheEnd_whenLabellingBars_thenTheWholeCommandIsInTheLabel() async {
        // given
        let prefix = String(repeating: "verify-step-", count: 30)
        let first = approvalCaptureRequest(owner: "monitor", id: "req-a", command: prefix + "alpha\nsecond line", createdAt: 1)
        let second = approvalCaptureRequest(owner: "monitor", id: "req-b", command: prefix + "omega", createdAt: 2)
        let (controller, _) = await controller(for: [first, second])
        // when
        let labels = controller.cards.map(\.barLabel)
        // then: tool first, no waiting prefix, lines collapsed, nothing cut to a prefix
        #expect(labels.count == 2 && labels[0] != labels[1])
        #expect(labels[0] == "Bash · " + prefix + "alpha second line")
        #expect(labels[1] == "Bash · " + prefix + "omega")
        #expect(!labels[0].contains("Waiting for approval"))
    }

    struct BarViewportRow: Sendable {
        let count: Int
        let bars: CGFloat
        let tallest: CGFloat
        let region: CGFloat
        let minViewport: CGFloat
        let expected: CGFloat
    }

    @Test(arguments: [
        // single bar: never capped, whatever the room
        BarViewportRow(count: 1, bars: 90, tallest: 80, region: 60, minViewport: 80, expected: 90),
        // several bars that fit: natural height
        BarViewportRow(count: 2, bars: 140, tallest: 72, region: 225, minViewport: 80, expected: 140),
        // several bars beyond the room: the card viewport keeps 80
        BarViewportRow(count: 6, bars: 400, tallest: 72, region: 225, minViewport: 80, expected: 145),
        // the cap never goes below the tallest single bar
        BarViewportRow(count: 6, bars: 400, tallest: 72, region: 120, minViewport: 80, expected: 72),
        // a small card asks for less than 80
        BarViewportRow(count: 6, bars: 400, tallest: 72, region: 225, minViewport: 30, expected: 195),
        // never above the region
        BarViewportRow(count: 6, bars: 400, tallest: 300, region: 225, minViewport: 80, expected: 225)
    ])
    func givenBars_whenSizingTheBarViewport_thenCardViewportSurvivesAndSingleBarIsNeverCapped(_ row: BarViewportRow) {
        // given / when
        let height = CallerApprovalPinnedLayout.barViewportHeight(barCount: row.count, barsHeight: row.bars, tallestBar: row.tallest,
                                                                  region: row.region, minCardViewport: row.minViewport)
        // then
        #expect(height == row.expected)
    }
}
