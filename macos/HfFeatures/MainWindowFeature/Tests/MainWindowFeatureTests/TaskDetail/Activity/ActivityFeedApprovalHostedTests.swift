import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor
private final class ApprovalFeedFake: CallerApprovalUseCase {
    let request: CallerApprovalRequest
    let supportsResponses: Bool
    private(set) var responseCount = 0
    private(set) var decisions: [String] = []

    init(request: CallerApprovalRequest, supportsResponses: Bool) {
        self.request = request
        self.supportsResponses = supportsResponses
    }

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        CallerApprovalPage(requests: [request], total: 1)
    }

    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest { request }
    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        responseCount += 1
        decisions.append(decision)
        return request
    }

    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { supportsResponses }
}

@MainActor @Suite(.serialized)
struct ActivityFeedApprovalHostedTests {
    @Test
    func givenRevealBeforeWindowAttachment_whenNativeFeedPositions_thenApprovalRowIsVisibleAndBothIntentsAreConsumed() async throws {
        let request = approvalRequest(owner: "caller")
        let fake = ApprovalFeedFake(request: request, supportsResponses: true)
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: request.taskID, workflowRunID: nil)
        controller.revealPending()
        let state = ParallelColumnUIState()
        state.followLive.suspend()
        let host = NSHostingView(rootView: TimelinePaneView(model: model(), state: state, approvalController: controller))
        let (window, previousActivationPolicy, previousEnhancedAX) = try open(host)
        defer {
            close(window, previousActivationPolicy: previousActivationPolicy, previousEnhancedAX: previousEnhancedAX)
        }

        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return window.isKeyWindow && NSApplication.shared.isActive && state.viewportPositioned
                && controller.reveal == nil && controller.cards.first?.focusToken == nil
        }

        await waitUntil(timeout: 5) {
            guard let table = nativeDescendants(host).compactMap({ $0 as? ActivityFeedNativeTableView }).first,
                  let row = table.owner?.entries.firstIndex(where: { $0.id == "activity-approval-\(request.id)" }),
                  let scroll = table.enclosingScrollView else { return false }
            host.layoutSubtreeIfNeeded()
            return scroll.documentVisibleRect.intersects(table.rect(ofRow: row))
        }
        try #require(window.isKeyWindow && NSApplication.shared.isActive && state.viewportPositioned,
                     Comment(rawValue: focusDiagnostic(window)))
        try #require(controller.reveal == nil && controller.cards.first?.focusToken == nil)
        let table = try #require(nativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let row = try #require(table.owner?.entries.firstIndex { $0.id == "activity-approval-\(request.id)" })
        #expect(table.enclosingScrollView?.documentVisibleRect.intersects(table.rect(ofRow: row)) == true)
        #expect(controller.cards.first?.canRespond == true)
        #expect(controller.reveal == nil)
        #expect(controller.cards.first?.focusToken == nil)
        sendKey(.space, to: window)
        await waitUntil(timeout: 2) { fake.responseCount == 1 }
        #expect(fake.responseCount == 1, Comment(rawValue: focusDiagnostic(window)))
        #expect(fake.decisions == ["approve"])
        #expect(focusedAccessibilityIdentifier(window) == "approval-approve-\(request.id)" || fake.responseCount == 1,
                Comment(rawValue: focusDiagnostic(window)))
    }

    @Test
    func givenBlockedCallerApproval_whenRevealPrecedesAttachment_thenNativeRowRemainsVisibleAndReadOnly() async throws {
        let fake = ApprovalFeedFake(request: approvalRequest(owner: "caller", longAction: true), supportsResponses: false)
        let request = fake.request
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: request.taskID, workflowRunID: nil)
        controller.revealPending()
        let state = ParallelColumnUIState()
        state.followLive.suspend()
        let host = NSHostingView(rootView: TimelinePaneView(model: model(), state: state, approvalController: controller))
        let (window, previousActivationPolicy, previousEnhancedAX) = try open(host)
        defer {
            close(window, previousActivationPolicy: previousActivationPolicy, previousEnhancedAX: previousEnhancedAX)
        }
        let approvalID = "activity-approval-\(request.id)"
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            guard window.isKeyWindow, NSApplication.shared.isActive, state.viewportPositioned,
                  controller.reveal == nil, controller.cards.first?.focusToken == nil else { return false }
            guard let table = nativeDescendants(host).compactMap({ $0 as? ActivityFeedNativeTableView }).first,
                  let row = table.owner?.entries.firstIndex(where: { $0.id == approvalID }),
                  let scroll = table.enclosingScrollView else { return false }
            return scroll.documentVisibleRect.intersects(table.rect(ofRow: row))
                 }
        try #require(window.isKeyWindow && NSApplication.shared.isActive && state.viewportPositioned,
                     Comment(rawValue: focusDiagnostic(window)))
        try #require(controller.reveal == nil && controller.cards.first?.focusToken == nil)
        #expect(controller.cards.first?.canRespond == false)
        #expect(controller.cards.first?.notice?.isEmpty == false)
        #expect(controller.reveal == nil)
        #expect(controller.cards.first?.focusToken == nil)
        let table = try #require(nativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let row = try #require(table.owner?.entries.firstIndex { $0.id == approvalID })
        let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: false))
        let outerScroll = try #require(table.enclosingScrollView)
        let scrollViews = nativeDescendants(cell).compactMap { $0 as? NSScrollView }
        let outerOffset = outerScroll.contentView.bounds.origin.y
        let innerScroll = scrollViews.first
        let innerOffset = innerScroll?.contentView.bounds.origin.y
        sendKey(.pageDown, to: window)
        if let innerScroll {
            await waitUntil(timeout: 2) { innerScroll.contentView.bounds.origin.y != innerOffset }
        }
        #expect(fake.responseCount == 0)
        #expect(innerScroll?.contentView.bounds.origin.y != innerOffset,
                Comment(rawValue: focusDiagnostic(window)))
        #expect(outerScroll.contentView.bounds.origin.y == outerOffset,
                Comment(rawValue: focusDiagnostic(window)))
        #expect(innerScroll != nil, Comment(rawValue: focusDiagnostic(window)))
    }

    private func model() -> TimelinePaneModel {
        let rows = (0 ..< 28).map { index in
            ConversationTimelineRow(id: "history-\(index)", taskID: "approval-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem(String(repeating: "Historical activity \(index) ", count: 12), seq: index)), live: false)
        }
        return TimelinePaneModel(stepCountText: "28 steps", rows: rows, start: nil, emptyText: nil,
                                 subTaskStrip: nil, isLoading: false)
    }

    private func approvalRequest(owner: String, longAction: Bool = false) -> CallerApprovalRequest {
        CallerApprovalRequest(raw: [
            "request_id": .string("native-approval"), "task_id": .string("approval-task"),
            "action_digest": .string(String(repeating: "a", count: 64)), "owner_revision": .number(2),
            "generation": .string("native-generation"), "interaction_owner": .string(owner),
            "disposition": .string("pending"), "delivery": .string("pending"),
            "execution_outcome": .string("unknown"), "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970),
            "complete": .bool(true), "action": .object(["tool_name": .string("Bash"),
                "input": .object(["command": .string(longAction
                    ? String(repeating: "echo native approval ", count: 120)
                    : "echo native approval")])])
        ])
    }

    private func open(_ host: NSHostingView<TimelinePaneView>) throws -> (NSWindow, NSApplication.ActivationPolicy, Bool) {
        _ = NSApplication.shared
        let previousActivationPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.regular)
        let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhancedAX = NSApplication.shared.accessibilityAttributeValue(enhancedAX) as? Bool ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhancedAX)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return (window, previousActivationPolicy, previousEnhancedAX)
    }

    private func close(
        _ window: NSWindow,
        previousActivationPolicy: NSApplication.ActivationPolicy,
        previousEnhancedAX: Bool
    ) {
        window.contentView = nil
        window.close()
        let enhancedAX = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApplication.shared.accessibilitySetValue(previousEnhancedAX, forAttribute: enhancedAX)
        NSApplication.shared.setActivationPolicy(previousActivationPolicy)
    }

    private func nativeDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(nativeDescendants)
    }

    private func focusedAccessibilityIdentifier(_ window: NSWindow) -> String? {
        let object = (window.accessibilityAttributeValue(.focusedUIElement) as? NSObject)
            ?? (NSApplication.shared.accessibilityAttributeValue(.focusedUIElement) as? NSObject)
        guard let object, object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return object.perform(NSSelectorFromString("accessibilityIdentifier"))?.takeUnretainedValue() as? String
    }

    private func focusDiagnostic(_ window: NSWindow) -> String {
        let firstResponder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let accessibility = focusedAccessibilityIdentifier(window) ?? "nil"
        let state = "windowKey=\(window.isKeyWindow), appActive=\(NSApplication.shared.isActive)"
        let focus = "focusedAccessibilityIdentifier=\(accessibility), firstResponder=\(firstResponder)"
        return "\(state), \(focus)"
    }

    private enum TestKey {
        case space
        case pageDown
    }

    private func sendKey(_ key: TestKey, to window: NSWindow) {
        let characters: String
        let keyCode: UInt16
        switch key {
        case .space:
            characters = " "
            keyCode = 49
        case .pageDown:
            characters = "\u{F72D}"
            keyCode = 121
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) else { return }
            window.sendEvent(event)
        }
    }
}
