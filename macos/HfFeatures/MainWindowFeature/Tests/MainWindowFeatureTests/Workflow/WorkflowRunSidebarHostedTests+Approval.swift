import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRunSidebarHostedTests inline approvals

/// Hosted coverage for approvals rendered as expandable entries in the inspector's activity document.
extension WorkflowRunSidebarHostedTests {
    private static let minimumWindow = CGSize(width: 1000, height: 620)

    @Test(arguments: [ColorScheme.light, .dark])
    func givenTwoOversizedApprovals_whenWindowGrowsAndShrinks_thenEachCardAndDecisionRemainsReachable(appearance: ColorScheme) async throws {
        let requests = Self.overflowRequests()
        let fake = CallerApprovalCaptureFake(requests: requests)
        let ids = requests.map(\.id)
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: appearance, fake: fake, requestIDs: ids)
        defer { pane.close() }

        let feed = try #require(pane.activityFeed)
        let table = try #require(feed.documentView as? ActivityFeedNativeTableView)
        #expect(pane.activityFeeds.count == 1, "The inspector has one activity document")
        #expect(pane.hasNoApprovalInnerScroll, "Approval details and decisions use the main activity document")
        let entryIDs = table.owner?.entries.map(\.id) ?? []
        #expect(entryIDs.contains("activity-scoped-approval-task-task-0-req-big"))
        #expect(entryIDs.contains("activity-scoped-approval-task-task-0-req-two"))

        let secondDisclosure = try #require(pane.fixture.element("approval-disclosure-req-two"))
        let secondIndex = try #require(table.owner?.entries.firstIndex { $0.id.hasSuffix("-req-two") })
        let collapsedSecondHeight = table.rect(ofRow: secondIndex).height
        #expect(pane.fixture.press(secondDisclosure))
        await pane.settle(timeout: 5) {
            table.rect(ofRow: secondIndex).height > collapsedSecondHeight + 30
                && pane.fixture.element("approval-approve-req-two") != nil
        }

        for size in [Self.minimumWindow, CGSize(width: 1440, height: 900), Self.minimumWindow] {
            pane.fixture.window.setContentSize(size)
            await pane.settle { (pane.activityFeed?.bounds.height ?? 0) > 0 }
            try pane.capture("inline-approvals-\(Int(size.width))x\(Int(size.height))-\(appearance == .dark ? "dark" : "light")")
            for id in ids {
                for suffix in ["approve", "reject"] {
                    let identifier = "approval-\(suffix)-\(id)"
                    let frame = try await pane.revealControl(identifier, in: feed)
                    #expect(pane.frameIsVisibleInActivity(frame, feed: feed), "\(identifier) is visible in the main scroll document: \(frame)")
                }
            }
        }

        let firstDisclosure = try #require(pane.fixture.element("approval-disclosure-req-big"))
        #expect(pane.fixture.press(firstDisclosure))
        await pane.settle { !pane.containsText("line 1 of a multi-line description") }
        #expect(pane.containsText("pwd"), "Collapsing one request leaves its neighbor expanded")
        #expect(pane.fixture.press(try #require(pane.fixture.element("approval-disclosure-req-big"))))
        await pane.settle { pane.containsText("line 1 of a multi-line description") }

        let secondDecision = try await pane.revealControl("approval-approve-req-two", in: feed)
        #expect(pane.frameIsVisibleInActivity(secondDecision, feed: feed))
        try await pane.clickDecisionAtAXCenter("approval-approve-req-two", in: feed)
        let recorded = await pane.settle(timeout: 3) { fake.responseCount == 1 }
        #expect(recorded, "The pointer decision reaches the fake approval endpoint")
        #expect(fake.responses == [CallerApprovalCaptureFake.Response(requestID: "req-two", decision: "approve")])
    }

    @Test(arguments: ["approve", "reject"], [ColorScheme.light, .dark])
    func givenInlineApproval_whenDecisionIsPressed_thenTheFakeRecordsTheExactRequestAndOutcome(decision: String, appearance: ColorScheme) async throws {
        let request = approvalCaptureRequest(owner: "monitor", id: "req-decision", taskID: "task-0", command: "swift test")
        let fake = CallerApprovalCaptureFake(request: request)
        let identifier = "approval-\(decision)-req-decision"
        let pane = try await makeApprovalPane(size: Self.minimumWindow, appearance: appearance, fake: fake, requestIDs: [request.id])
        defer { pane.close() }

        let feed = try #require(pane.activityFeed)
        let frame = try await pane.revealControl(identifier, in: feed)
        #expect(pane.frameIsVisibleInActivity(frame, feed: feed))
        try await pane.clickDecisionAtAXCenter(identifier, in: feed)
        let recorded = await pane.settle(timeout: 3) { fake.responseCount == 1 }
        #expect(recorded, "The pointer decision reaches the fake approval endpoint")
        #expect(fake.responses == [CallerApprovalCaptureFake.Response(requestID: request.id, decision: decision)])
        let outcomeFocused = await pane.settle(timeout: 5) {
            (pane.fixture.window.firstResponder as? NSView)?.accessibilityIdentifier() == "approval-disclosure-\(request.id)"
        }
        #expect(outcomeFocused, "The answered request retains focus on its exact outcome disclosure")
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
    private func makeApprovalPane(size: CGSize, appearance: ColorScheme, fake: CallerApprovalCaptureFake,
                                  requestIDs: [String]) async throws -> ApprovalPane {
        let vm = WorkflowPreview.make(run: true)
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        var raw = try #require(vm.selectedRun?.raw)
        raw["caller_approvals"] = .bool(true)
        raw["goal"] = .string("Verify the release.")
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
        let selectedTaskReady = await pane.settle(timeout: 5) {
            vm.selectedNodeID == nodeID
                && vm.selectedActivity?.columns.first?.task.taskID == "task-0"
                && vm.selectedActivity?.columns.first?.inspectorApproval != nil
        }
        try #require(selectedTaskReady, "The selected task update mounts the retained approval activity")
        let ready = await pane.settle(timeout: 8) {
            fake.pageCalls.contains { $0.taskID == "task-0" }
                && Set(pane.activityEntryIDs).isSuperset(of: Set(requestIDs.map(pane.scopedApprovalEntryID)))
                && pane.approvalControllerSettled && pane.hasMeasuredActivityRows
        }
        if !ready {
            try pane.capture("approval-readiness-\(Int(size.width))x\(Int(size.height))-\(appearance == .dark ? "dark" : "light")")
        }
        let diagnostic = "expected=\(requestIDs), task=\(vm.activityMessageTarget.taskID ?? "nil"), "
            + "pages=\(fake.pageCalls.map(\.taskID)), entries=\(pane.activityEntryIDs), "
            + "status=\(pane.approvalStatus), width=\(pane.activityWidth), positioned=\(pane.activityPositioned)"
        try #require(ready, Comment(rawValue: diagnostic))
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

    func settle(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        var reached = false
        await waitUntil(timeout: timeout) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            fixture.host.layoutSubtreeIfNeeded()
            fixture.host.displayIfNeeded()
            reached = predicate()
            return reached
        }
        return reached
    }

    var paneView: NSView? { fixture.descendants.compactMap { $0 as? NSSplitView }.last { $0.isVertical }?.arrangedSubviews.last }
    var paneScrollViews: [NSScrollView] { paneView.map { allViews($0).compactMap { $0 as? NSScrollView } } ?? [] }
    var activityFeeds: [ActivityFeedNativeScrollView] { paneScrollViews.compactMap { $0 as? ActivityFeedNativeScrollView } }
    var activityFeed: ActivityFeedNativeScrollView? { activityFeeds.first }
    var activityEntryIDs: [String] {
        guard let table = activityFeed?.documentView as? ActivityFeedNativeTableView else { return [] }
        return table.owner?.entries.map(\.id) ?? []
    }

    var approvalStatus: String {
        guard let table = activityFeed?.documentView as? ActivityFeedNativeTableView else { return "missing table" }
        for entry in table.owner?.entries ?? [] {
            guard case .supplementary(let row) = entry else { continue }
            switch row.input {
            case .approval(let status), .approvalCards(_, let status):
                return "loading=\(status.loading) error=\(String(describing: status.error))"
            default:
                continue
            }
        }
        return "missing"
    }

    var activityWidth: CGFloat { activityFeed?.owner?.currentWidth ?? 0 }
    var activityPositioned: Bool { activityFeed?.owner?.positioned == true }
    var hasMeasuredActivityRows: Bool {
        guard let table = activityFeed?.documentView as? ActivityFeedNativeTableView,
              let owner = table.owner else { return false }
        return owner.positioned && owner.currentWidth > 0 && owner.boxes.count == owner.entries.count
            && owner.boxes.contains { ($0.height ?? 0) > 0 }
    }

    var approvalControllerSettled: Bool {
        guard let table = activityFeed?.documentView as? ActivityFeedNativeTableView else { return false }
        for entry in table.owner?.entries ?? [] {
            guard case .supplementary(let row) = entry else { continue }
            switch row.input {
            case .approval(let status), .approvalCards(_, let status): return !status.loading
            default: continue
            }
        }
        return false
    }

    func scopedApprovalEntryID(_ requestID: String) -> String {
        "activity-scoped-approval-task-task-0-\(requestID)"
    }

    func windowFrame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
    var hasNoApprovalInnerScroll: Bool {
        guard let paneView else { return false }
        return allViews(paneView).compactMap { $0 as? NSScrollView }.allSatisfy {
            !$0.accessibilityIdentifier().hasPrefix("approval-details-")
        }
    }

    func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
    func containsText(_ text: String) -> Bool {
        guard let paneView else { return false }
        return allViews(paneView).flatMap { fixture.elements(in: $0) }.contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(element, $0)?.contains(text) == true
            }
        }
    }

    func revealControl(_ identifier: String, in feed: ActivityFeedNativeScrollView) async throws -> CGRect {
        let requestID = identifier.components(separatedBy: "-").last ?? ""
        guard let document = feed.documentView,
              let table = document as? ActivityFeedNativeTableView else {
            Issue.record("Activity document is missing")
            return .zero
        }

        var latestFrame = CGRect.zero
        var latestViewport = CGRect.zero
        var latestPaneViewport = CGRect.zero
        var latestRow = CGRect.zero
        for _ in 0 ..< 4 {
            let mounted = await settle(timeout: 2) {
                fixture.element(identifier) != nil
                    && feed.owner?.entries.contains { $0.id.hasSuffix("-\(requestID)") } == true
            }
            try #require(mounted, "The exact approval control and row are mounted: \(identifier)")
            guard let element = fixture.element(identifier), let frame = fixture.frame(element),
                  let row = feed.owner?.entries.firstIndex(where: { $0.id.hasSuffix("-\(requestID)") })
            else { continue }

            latestFrame = frame
            latestViewport = feed.contentView.convert(feed.contentView.bounds, to: nil)
            latestPaneViewport = feed.convert(feed.bounds, to: nil)
            latestRow = table.rect(ofRow: row)
            if latestViewport.insetBy(dx: -1, dy: -1).contains(frame) { return frame }

            document.scrollToVisible(document.convert(frame, from: nil))
            feed.reflectScrolledClipView(feed.contentView)
            fixture.host.layoutSubtreeIfNeeded()
            let visible = await settle(timeout: 1) {
                guard let currentElement = fixture.element(identifier),
                      let currentFrame = fixture.frame(currentElement) else { return false }
                latestFrame = currentFrame
                latestViewport = feed.contentView.convert(feed.contentView.bounds, to: nil)
                latestPaneViewport = feed.convert(feed.bounds, to: nil)
                return latestViewport.insetBy(dx: -1, dy: -1).contains(currentFrame)
            }
            if visible { return latestFrame }
        }

        let diagnostic = "\(identifier) failed to fit current activity viewport: frame=\(latestFrame), viewport=\(latestViewport), "
            + "pane=\(latestPaneViewport), row=\(latestRow), document=\(document.bounds)"
        try #require(false, Comment(rawValue: diagnostic))
        return latestFrame
    }

    func frameIsVisibleInActivity(_ frame: CGRect, feed: ActivityFeedNativeScrollView) -> Bool {
        let viewport = feed.contentView.convert(feed.contentView.bounds, to: nil)
        return viewport.insetBy(dx: -1, dy: -1).contains(frame)
    }

    func clickDecisionAtAXCenter(_ identifier: String, in feed: ActivityFeedNativeScrollView) async throws {
        let priorActivationPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(priorActivationPolicy) }
        try await resourceInteractionForeground(fixture)
        _ = try await revealControl(identifier, in: feed)

        var frame = CGRect.zero
        let ready = await settle(timeout: 5) {
            guard let element = fixture.element(identifier), let currentFrame = fixture.frame(element),
                  !currentFrame.isEmpty, frameIsVisibleInActivity(currentFrame, feed: feed) else { return false }
            // Approve is AppKit-backed. Reject is a SwiftUI button exposed through AX.
            guard element.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return false }
            let enabled = (element as? any NSAccessibilityProtocol)?.isAccessibilityEnabled()
                ?? (element.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue
            guard enabled == true else { return false }
            frame = currentFrame
            return true
        }
        let viewport = feed.contentView.convert(feed.contentView.bounds, to: nil)
        let diagnostic = "Enabled decision after foreground activation: id=\(identifier), frame=\(frame), viewport=\(viewport)"
        try #require(ready, Comment(rawValue: diagnostic))

        let point = CGPoint(x: frame.midX, y: frame.midY)
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        NSApp.postEvent(mouseUp, atStart: false)
        fixture.window.sendEvent(mouseDown)
    }

    func capture(_ name: String) throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARFLOW_APPROVAL_CAPTURE_DIR"] ?? NSTemporaryDirectory(),
                            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture.host.layoutSubtreeIfNeeded()
        let bitmap = try #require(fixture.host.bitmapImageRepForCachingDisplay(in: fixture.host.bounds))
        fixture.host.cacheDisplay(in: fixture.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
