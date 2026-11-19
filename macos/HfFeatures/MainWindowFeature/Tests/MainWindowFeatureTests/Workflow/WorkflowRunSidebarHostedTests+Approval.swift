import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRunSidebarHostedTests pending approval

/// The owner rule for a caller approval awaiting a decision in the selected-node pane's inspector column: the card gets its
/// natural height first, the feed yields, the goal region yields after the feed, and an oversized card scrolls above its
/// pinned Approve once and Reject bars. Visibility is proved by geometry (frames inside the visible region above the
/// composer) and by activation through accessibility.
extension WorkflowRunSidebarHostedTests {
    private static let minimumWindow = CGSize(width: 1000, height: 620)
    private static let longGoal = (1 ... 10)
.map {
        "Step \($0): confirm the release notes, the changelog entry and the migration receipt agree with the shipped build."
    }
.joined(separator: " ")

    // MARK: Minimum window

    @Test(arguments: [ColorScheme.light, .dark])
    func givenPendingRequestAtMinimumWindow_whenLaidOut_thenFeedAndGoalRegionYieldAndCardScrollsAbovePinnedActions(appearance: ColorScheme) async throws {
        // given: a realistic single-field Bash request; the 1000x620 chrome leaves less room than its natural height
        let request = approvalCaptureRequest(owner: "monitor", id: "req-fit", taskID: "task-0", command: "swift test --filter PersistenceTests")
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: appearance, fake: CallerApprovalCaptureFake(request: request),
                                              waitFor: ["approval-approve-req-fit"])
        defer { pane.close() }

        // when
        let metrics = try pane.metrics(requestIDs: ["req-fit"])
        try pane.capture("fit-1000x620-\(appearance == .dark ? "dark" : "light")")

        // then
        #expect(metrics.demand.awaitingDecision)
        #expect(metrics.regionIsVisible, "The region is inside the window and the pane and above the composer: \(metrics.description)")
        #expect(metrics.feedHeight < 1, "The feed has yielded down to the step-count line")
        #expect(metrics.topRegionHeight < 1, "The goal region has yielded after the feed")
        #expect(metrics.stepCountLinePresent, "The step-count line stays")
        #expect(metrics.regionHeight < metrics.demand.natural, "The column's chrome leaves the card less than its natural height")
        #expect(metrics.cardScrolls, "so the card scrolls inside its region")
        #expect(metrics.actionsAreVisible, "Approve once and Reject are whole inside the region")
        #expect(metrics.cardScrollKeepsActionsFixed(pane), "Scrolling the card to its end and back leaves the actions in place")
        #expect(metrics.allHitsReachTheirTarget, "Every action answers its own hit test: \(metrics.hitTests)")
    }

    // MARK: Overflow

    @Test(arguments: [ColorScheme.light, .dark])
    func givenOversizedCardAndTwoRequests_whenWindowIsAtMinimum_thenBarsStackNameTheirRequestsAndEveryActionIsReachable(appearance: ColorScheme) async throws {
        // given
        let fake = CallerApprovalCaptureFake(requests: Self.overflowRequests())
        let ids = fake.requests.map(\.id)
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: appearance, fake: fake,
                                              waitFor: ids.map { "approval-approve-\($0)" })
        defer { pane.close() }

        // when
        let metrics = try pane.metrics(requestIDs: ids)
        try pane.capture("overflow-1000x620-\(appearance == .dark ? "dark" : "light")")

        // then
        #expect(metrics.demand.awaitingDecision)
        #expect(metrics.regionHeight < metrics.demand.natural - 1, "The card is larger than the room the column leaves")
        #expect(metrics.regionIsVisible)
        #expect(metrics.barLabelsPresent(ids), "Each of the two bars names its request")
        #expect(metrics.actionsAreVisible, "Both bars' four actions are inside the region without scrolling the bar stack")
        #expect(metrics.allHitsReachTheirTarget, "Every action answers its own hit test: \(metrics.hitTests)")
        #expect(metrics.cardScrolls, "The oversized card scrolls above the bars")
        #expect(metrics.cardScrollKeepsActionsFixed(pane), "Scrolling the card to its end and back leaves every action in place")
    }

    // MARK: Many bars

    @Test(arguments: [ColorScheme.light, .dark])
    func givenMoreBarsThanTheRegionHolds_whenBarStackScrolls_thenCardViewportSurvivesAndEveryRequestIsReachable(appearance: ColorScheme) async throws {
        // given
        let requests = (0 ..< 6).map {
            approvalCaptureRequest(owner: "monitor", id: "req-m\($0)", taskID: "task-0", command: "echo step \($0)", createdAt: Double($0))
        }
        let fake = CallerApprovalCaptureFake(requests: requests)
        let ids = requests.map(\.id)
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: appearance, fake: fake,
                                              waitFor: ids.map { "approval-approve-\($0)" })
        defer { pane.close() }
        let metrics = try pane.metrics(requestIDs: ids)
        try pane.capture("many-bars-1000x620-\(appearance == .dark ? "dark" : "light")")

        // when / then
        #expect(metrics.regionIsVisible)
        #expect(metrics.barStackScrolls, "The stacked bars exceed the room, so the bar stack scrolls")
        #expect(metrics.cardViewportHeight >= CallerApprovalPinnedLayout.minimumCardViewport - 1, "The cards keep a viewport: \(metrics.description)")
        for id in ids {
            let reach = try pane.scrollIntoView(requestID: id)
            #expect(reach.approve && reach.reject, "Both actions of \(id) are inside the bar viewport after scrolling it into view")
            #expect(reach.viewportAboveComposer)
            let details = try pane.scrollDetailsIntoView(requestID: id)
            #expect(details.isReachable, "The details of \(id) come into the card viewport: \(details)")
        }
    }

    // MARK: Labels

    @Test(arguments: [ColorScheme.light, .dark])
    func givenTwoCommandsSharingALongPrefix_whenBarsAreLabelled_thenTheLabelsDifferVisiblyAndAccessibly(appearance: ColorScheme) async throws {
        // given: the commands differ only in their last word, far past where a tail-truncated label would end
        let prefix = String(repeating: "run-the-long-verification-step-with-every-argument-spelled-out ", count: 4)
        let first = approvalCaptureRequest(owner: "monitor", id: "req-a", taskID: "task-0", command: prefix + "alpha", createdAt: 1)
        let second = approvalCaptureRequest(owner: "monitor", id: "req-b", taskID: "task-0", command: prefix + "omega", createdAt: 2)
        let fake = CallerApprovalCaptureFake(requests: [first, second])
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: appearance, fake: fake,
                                              waitFor: ["approval-approve-req-a", "approval-approve-req-b"])
        defer { pane.close() }

        // when
        let metrics = try pane.metrics(requestIDs: ["req-a", "req-b"])
        let labelA = try #require(pane.fixture.element("approval-bar-label-req-a"))
        let labelB = try #require(pane.fixture.element("approval-bar-label-req-b"))
        func text(_ element: NSObject) -> String? {
            ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { pane.fixture.string(element, $0) }.first
        }
        let textA = try #require(text(labelA))
        let textB = try #require(text(labelB))

        // then: the accessibility text carries the whole command, so the two differ at the end; the visible line is one line
        // truncated in the middle, so its end (the differing word) stays on screen
        #expect(textA != textB)
        #expect(textA.hasSuffix("alpha") && textB.hasSuffix("omega"), "\(textA) | \(textB)")
        #expect(textA.hasPrefix("Bash · ") && !textA.contains("Waiting for approval"))
        #expect(pane.fixture.string(labelA, "accessibilityHelp") == textA, "The full text is the label's help")
        #expect(metrics.barLabelsPresent(["req-a", "req-b"]))
        #expect(metrics.labels.count == 2 && metrics.labels.values.allSatisfy { $0.height < 20 }, "Each label is a single line")
        #expect(metrics.actionsAreVisible)
    }

    // MARK: History

    @Test
    func givenOnePendingRequestAndSettledHistory_whenLaidOut_thenTheDemandIsThePendingCardAlone() async throws {
        // given: one pending request alone in the pane
        let pending = approvalCaptureRequest(owner: "monitor", id: "req-p", taskID: "task-0", command: "swift test --filter PersistenceTests", createdAt: 50)
        let fake = CallerApprovalCaptureFake(request: pending)
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: .light, fake: fake, waitFor: ["approval-approve-req-p"])
        defer { pane.close() }
        let alone = try pane.metrics(requestIDs: ["req-p"])
        let aloneDocument = alone.cardScroll?.documentView?.frame.height ?? 0

        // when: answered and expired requests arrive with the next poll (an expired card is expanded by default)
        fake.requests = [pending,
            approvalCaptureRequest(owner: "monitor", id: "req-d1", taskID: "task-0", command: "ls", disposition: "decided", createdAt: 10),
            approvalCaptureRequest(owner: "monitor", id: "req-d2", taskID: "task-0", command: "pwd", disposition: "decided", createdAt: 20),
            approvalCaptureRequest(owner: "monitor", id: "req-x1", taskID: "task-0", command: "make", disposition: "expired", createdAt: 30)]
        await pane.settle(timeout: 10) {
            ((try? pane.metrics(requestIDs: ["req-p"]))?.cardScroll?.documentView?.frame.height ?? 0) > aloneDocument + 50
        }
        await pane.settle(timeout: 1) { false }
        let metrics = try pane.metrics(requestIDs: ["req-p"])
        try pane.capture("history-1000x620-light")

        // then
        let document = metrics.cardScroll?.documentView?.frame.height ?? 0
        #expect(document > aloneDocument + 50, "The history is really in the card scroll: \(document) against \(aloneDocument)")
        #expect(abs(metrics.demand.natural - alone.demand.natural) < 0.5, "Only the pending card is demanded")
        #expect(metrics.demand.awaitingDecision)
        #expect(abs(metrics.feedHeight - alone.feedHeight) < 0.5, "The history does not move the feed")
        #expect(abs(metrics.topRegionHeight - alone.topRegionHeight) < 0.5, "The history does not move the goal region")
        #expect(abs(metrics.regionHeight - alone.regionHeight) < 0.5, "The history does not resize the region")
        #expect(metrics.actionsAreVisible && metrics.regionIsVisible)
    }

    // MARK: Ordering

    @Test
    func givenExpandedHistoryAndAnUnknownStatePendingRequest_whenLaidOut_thenTheAwaitingCardRendersFirstInTheCardViewport() async throws {
        // given: the app's own ordering (`CallerApprovalPresentation.orderedBefore`) sorts an unknown-disposition request that is still pending among settled history, and an older
        // expired request is expanded by default
        let expired = approvalCaptureRequest(owner: "monitor", id: "req-old", taskID: "task-0", command: "old-expired-command-marker",
                                             disposition: "expired", createdAt: 1)
        let unknown = approvalCaptureRequest(owner: "monitor", id: "req-new", taskID: "task-0", command: "unknown-state-command-marker",
                                             disposition: "pending", createdAt: 2)
        var raw = unknown.raw
        raw["disposition"] = .string("future_state")
        let fake = CallerApprovalCaptureFake(requests: [expired, CallerApprovalRequest(raw: raw)])
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: .light, fake: fake, waitFor: ["approval-details-req-new"])
        defer { pane.close() }

        // when
        let metrics = try pane.metrics(requestIDs: ["req-new"])
        try pane.capture("ordering-1000x620-light")

        // then
        let awaitingFirst = try #require(pane.frame(ofElementContaining: "unknown-state-command-marker"))
        let viewport = try #require(metrics.cardScroll.map { pane.windowFrame($0.contentView) })
        #expect(metrics.demand.awaitingDecision, "The unknown-state request is visually pending")
        #expect(metrics.cardViewportHeight > 0)
        #expect(viewport.insetBy(dx: -1, dy: -1).contains(CGPoint(x: awaitingFirst.midX, y: awaitingFirst.midY)),
                "The awaiting card starts inside the card viewport: \(awaitingFirst) in \(viewport)")
        let history = try #require(pane.frame(ofElementContaining: "old-expired-command-marker"), "The expired card is expanded by default")
        #expect(awaitingFirst.maxY > history.maxY, "The awaiting card is above the expanded history")
        let details = try #require(metrics.details["req-new"])
        let oldDetails = try #require(pane.fixture.element("approval-details-req-old").flatMap { pane.fixture.frame($0) })
        #expect(details.maxY > oldDetails.maxY, "The awaiting card renders before the expired one")
        #expect(metrics.approves["req-new"] == nil && metrics.rejects["req-new"] == nil, "An unknown state is never actionable, so it has no bar")
    }

    // MARK: Activation

    @Test(arguments: ["approve", "reject"], [ColorScheme.light, .dark])
    func givenTwoPendingRequests_whenTheSecondBarIsPressed_thenTheFakeRecordsItsRequestAndDecision(decision: String, appearance: ColorScheme) async throws {
        // given
        let fake = CallerApprovalCaptureFake(requests: Self.overflowRequests())
        let ids = fake.requests.map(\.id)
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: appearance, fake: fake,
                                              waitFor: ids.map { "approval-approve-\($0)" })
        defer { pane.close() }
        let target = try #require(ids.last)
        let reach = try pane.scrollIntoView(requestID: target)
        #expect(reach.approve && reach.reject)
        let identifier = decision == "approve" ? "approval-approve-\(target)" : "approval-reject-\(target)"
        let button = try #require(pane.fixture.element(identifier))

        // when: a press that lands while the panel's 3 s poll is mid-refresh is ignored by the controller, as a click is for
        // a person, so the press is repeated (at most four times) until the fake has an answer
        for _ in 0 ..< 4 where fake.responseCount == 0 {
            #expect(pane.fixture.press(button), "The accessibility press of \(identifier) is accepted")
            await pane.settle(timeout: 1.5) { fake.responseCount > 0 }
        }

        // then
        #expect(fake.responses == [CallerApprovalCaptureFake.Response(requestID: target, decision: decision)])
    }

    // MARK: Resolution

    @Test
    func givenPendingRequest_whenItSettles_thenTheFeedFloorComesBack() async throws {
        // given
        let request = approvalCaptureRequest(owner: "monitor", id: "req-resolve", taskID: "task-0", command: "swift test --filter PersistenceTests")
        let fake = CallerApprovalCaptureFake(request: request)
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: .light, fake: fake, waitFor: ["approval-approve-req-resolve"])
        defer { pane.close() }
        #expect(pane.demand.value.awaitingDecision)
        let pendingFeed = try #require(paneFeed(in: pane.fixture)).bounds.height

        // when: the engine reports the request answered; the panel's next 3 s poll reads it
        fake.requests = [approvalCaptureRequest(owner: "monitor", id: "req-resolve", taskID: "task-0",
                                                command: "swift test --filter PersistenceTests", disposition: "decided")]
        func barButton() -> NSView? {
            pane.paneView.flatMap { root in pane.allViews(root).first {
                $0.accessibilityIdentifier() == "approval-approve-req-resolve" && $0.window != nil
                    && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            } }
        }
        await pane.settle(timeout: 10) {
            !pane.demand.value.awaitingDecision && barButton() == nil
                && (paneFeed(in: pane.fixture)?.bounds.height ?? 0) >= WorkflowSelectedPaneSizing.transcriptFloor - 0.5
        }

        // then
        let feed = try #require(paneFeed(in: pane.fixture))
        try pane.capture("resolved-1000x620-light")
        #expect(pane.demand.value.awaitingDecision == false)
        #expect(pane.demand.value.reserved == 0)
        #expect(feed.bounds.height >= WorkflowSelectedPaneSizing.transcriptFloor - 0.5, "The feed's 80 pt floor is back")
        #expect(barButton() == nil, "The pinned bar is gone")
    }

    // MARK: Large window

    @Test
    func givenPendingRequestInALargeWindow_whenLaidOut_thenCardAndGoalRegionKeepTheirNaturalHeightsAndTheFeedKeepsWhatIsLeft() async throws {
        // given
        let request = approvalCaptureRequest(owner: "monitor", id: "req-large", taskID: "task-0", command: "swift test --filter PersistenceTests")
        let pane = try await makeApprovalPane(size: CGSize(width: 1440, height: 900), appearance: .light,
                                              fake: CallerApprovalCaptureFake(request: request), waitFor: ["approval-approve-req-large"],
                                              goal: "Verify the release.")
        defer { pane.close() }

        // when
        let metrics = try pane.metrics(requestIDs: ["req-large"])
        try pane.capture("pending-1440x900-light")

        // then: at 1440x900 the card, the goal block and the step line all fit; the feed gets what is left, which is below its 80 pt floor
        #expect(abs(metrics.regionHeight - metrics.demand.natural) <= 1.5, "The card is at its natural height")
        #expect(metrics.actionsAreVisible && metrics.regionIsVisible && metrics.detailsAreInsideRegion)
        #expect(metrics.topRegionIsNatural, "The goal region keeps its natural height")
        #expect(!metrics.cardScrolls, "The card does not scroll")
        #expect(metrics.feedHeight > 0, "The feed keeps what is left")
    }

    // MARK: Fixtures

    private static func overflowRequests() -> [CallerApprovalRequest] {
        let command = (1 ... 14).map { "step \($0): run the long verification command with every argument spelled out in full" }.joined(separator: "\n")
        let big = approvalCaptureRequest(
            owner: "monitor", id: "req-big", taskID: "task-0", command: command,
            extraFields: ["description": (1 ... 6).map { "line \($0) of a multi-line description that makes this card taller" }.joined(separator: "\n"),
                          "cwd_hint": "/tmp/harflow-capture/very/long/path/that/keeps/going"],
            reason: (1 ... 8).map { "Reason sentence \($0) explains why the agent wants to run this command now." }.joined(separator: " "),
            createdAt: 10)
        let second = approvalCaptureRequest(owner: "monitor", id: "req-two", taskID: "task-0", command: "pwd", createdAt: 20)
        return [big, second]
    }

    @MainActor
    private func makeApprovalPane(size: CGSize, appearance: ColorScheme, fake: CallerApprovalCaptureFake, waitFor identifiers: [String],
                                  goal: String? = nil) async throws -> ApprovalPane {
        let vm = WorkflowPreview.make(run: true)
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        var raw = try #require(vm.selectedRun?.raw)
        raw["caller_approvals"] = .bool(true)
        raw["goal"] = .string(goal ?? Self.longGoal)
        raw["activations"] = .array([workerActivation(nodeID: nodeID, taskID: "task-0")])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        let parallelTests = ParallelVMTests()
        let harness = parallelTests.makeSUT()
        harness.tasksBox.value["task-0"] = parallelTests.task(id: "task-0", status: "running")
        harness.itemsBox.value["task-0"] = [PreviewFixtures.textItem("Node activity")]
        harness.availabilityBox.value["task-0"] = .available
        vm.parallel = harness.sut
        let demand = DemandBox()
        let useCase: any CallerApprovalUseCase = fake
        let root = WorkflowView(vm)
            .preferredColorScheme(appearance)
            .environment(\.callerApprovalUseCaseOverride, { useCase })
            .onPreferenceChange(CallerApprovalDemandKey.self) { value in MainActor.assumeIsolated { demand.value = value } }
        let fixture = RedesignHost(root, size: size, appearance: appearance)
        let pane = ApprovalPane(vm: vm, harness: harness, fixture: fixture, fake: fake, demand: demand)
        vm.selectedNodeID = nodeID
        await vm.sidebarTask?.value
        harness.tasksSubject.send(Array(harness.tasksBox.value.values))
        await pane.settle(timeout: 8) { identifiers.allSatisfy { fixture.element($0) != nil } && pane.demand.value.natural > 0 }
        // The layout needs a few passes after the cards appear: demand, region, then the pane's top region.
        await pane.settle(timeout: 2) { false }
        for identifier in identifiers { #expect(fixture.element(identifier) != nil, "\(identifier) is on screen") }
        return pane
    }
}

// MARK: - DemandBox

@MainActor
final class DemandBox {
    var value = CallerApprovalDemand()
}

// MARK: - ApprovalPane

@MainActor
struct ApprovalPane {
    let vm: WorkflowVM
    let harness: ParallelVMTests.SUT
    let fixture: RedesignHost
    let fake: CallerApprovalCaptureFake
    let demand: DemandBox

    func close() {
        vm.didDisappear()
        fixture.close()
    }

    /// Pumps layout until `predicate` holds or the timeout passes.
    func settle(timeout: TimeInterval = 3, _ predicate: () -> Bool) async {
        await waitUntil(timeout: timeout) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            fixture.host.layoutSubtreeIfNeeded()
            fixture.host.displayIfNeeded()
            return predicate()
        }
    }

    var paneView: NSView? { fixture.descendants.compactMap { $0 as? NSSplitView }.last { $0.isVertical }?.arrangedSubviews.last }

    var paneScrollViews: [NSScrollView] {
        paneView.map { allViews($0).compactMap { $0 as? NSScrollView } } ?? []
    }

    func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    func windowFrame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    func capture(_ name: String) throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARFLOW_APPROVAL_CAPTURE_DIR"] ?? NSTemporaryDirectory(),
                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = fixture.host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    func metrics(requestIDs: [String]) throws -> ApprovalMetrics {
        try ApprovalMetrics(pane: self, requestIDs: requestIDs)
    }
}
