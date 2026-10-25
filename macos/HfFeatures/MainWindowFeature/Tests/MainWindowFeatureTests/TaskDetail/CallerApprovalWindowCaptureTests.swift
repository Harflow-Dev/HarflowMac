import AppKit
import Foundation
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor
private final class CallerApprovalCaptureFake: CallerApprovalUseCase {
    let request: CallerApprovalRequest
    var responseCount = 0
    var supportsCallerResponses = false

    init(request: CallerApprovalRequest) { self.request = request }

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        CallerApprovalPage(requests: [request], total: 1)
    }

    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest { request }

    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        responseCount += 1
        return request
    }

    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { supportsCallerResponses }
}

private func captureRequest(owner: String) -> CallerApprovalRequest {
    let longCommand = [
        "python3 -c \"open('approval-marker.txt','a').write('APPROVED')\"",
        "--long-command-scroll-probe-abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-",
        "abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrstuvwxyz-0123456789"
    ].joined()
    return CallerApprovalRequest(raw: [
        "request_id": .string("capture-\(owner)"),
        "task_id": .string("task-capture"),
        "action_digest": .string(String(repeating: "a", count: 64)),
        "owner_revision": .number(4),
        "generation": .string("generation-capture"),
        "interaction_owner": .string(owner),
        "disposition": .string("pending"),
        "delivery": .string("pending"),
        "execution_outcome": .string("unknown"),
        "tool_name": .string("Bash"),
        "cwd": .string("/tmp/harflow-capture"),
        "freedom": .string("workspace-write"),
        "scope": .string("caller approval capture"),
        "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970),
        "complete": .bool(true),
        "action": .object([
            "tool_name": .string("Bash"),
            "input": .object([
                "command": .string(longCommand)
            ])
        ])
    ])
}

@MainActor @Suite(.serialized)
struct CallerApprovalWindowCaptureTests {
    @Test
    func capturesLightDarkAndCallerOwnedReadOnlyCardsInRealWindows() async throws {
        let configuredRoot = ProcessInfo.processInfo.environment["PB61_UI_CAPTURE_DIR"]
        let root = URL(fileURLWithPath: configuredRoot ?? NSTemporaryDirectory())
            .appendingPathComponent(configuredRoot == nil ? "hf61-ui-captures-\(UUID().uuidString)" : "")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let cases: [(String, ColorScheme?, String, Bool)] = [
            ("caller-approval-light", .light, "monitor", false),
            ("caller-approval-dark", .dark, "monitor", false),
            ("caller-approval-caller-owned", .light, "caller", false),
            ("caller-approval-caller-enabled", .dark, "caller", true)
        ]
        for (name, scheme, owner, supportsCallerResponses) in cases {
            let request = captureRequest(owner: owner)
            let fake = CallerApprovalCaptureFake(request: request)
            fake.supportsCallerResponses = supportsCallerResponses
            let controller = CallerApprovalController(useCase: fake)
            await controller.selectTarget(taskID: "task-capture", workflowRunID: nil)
            await controller.inspect(request)
            #expect(controller.isCurrentDetail == (owner == "monitor" || supportsCallerResponses))
            #expect(controller.detail?.raw["action"]?.rendered(pretty: true).contains("long-command-scroll-probe") == true)

            let view = CallerApprovalCard(controller: controller)
                .frame(width: 620, alignment: .leading)
                .preferredColorScheme(scheme)
            let host = RedesignHost(view, size: CGSize(width: 1440, height: 900), appearance: scheme)
            defer { host.close() }
            host.window.makeKeyAndOrderFront(nil)
            await host.settle { host.hasRenderedInk }
            #expect(host.hasRenderedInk)
            controller.revealPending()
            await host.settle { host.window.firstResponder != nil }
            #expect(host.window.firstResponder != nil)
            if owner == "monitor" || supportsCallerResponses {
                let approve = try #require(host.element("Approve once"))
                let reject = try #require(host.element("Reject"))
                #expect(controller.isCurrentDetail)
                #expect(approve.responds(to: NSSelectorFromString("accessibilityPerformPress")))
                #expect(reject.responds(to: NSSelectorFromString("accessibilityPerformPress")))
            } else {
                #expect(controller.isCurrentDetail == false)
                #expect(host.element("Approve once") == nil)
                #expect(host.element("Reject") == nil)
            }
            #expect(controller.cards.first?.action.fields.first(where: { $0.id == "input/command" })?.value.contains("long-command-scroll-probe") == true)
            try captureWindowBackedPNG(host, to: root.appendingPathComponent(name + ".png"))
            if owner == "monitor" || supportsCallerResponses {
                let approve = try #require(host.element("Approve once"))
                #expect(host.press(approve))
                await host.settle { fake.responseCount == 1 }
                #expect(fake.responseCount == 1)
            }
        }
        let captures = try FileManager.default
.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        #expect(captures.count == 4)
    }

    @Test
    func givenActionableApprovalUnderDisabledAncestor_whenNativeApproveIsPressed_thenItRemainsDisabled() async throws {
        let request = captureRequest(owner: "caller")
        let fake = CallerApprovalCaptureFake(request: request)
        fake.supportsCallerResponses = true
        let controller = CallerApprovalController(useCase: fake)
        await controller.selectTarget(taskID: request.taskID, workflowRunID: nil)
        await controller.inspect(request)
        let view = VStack {
            CallerApprovalCard(controller: controller)
        }.disabled(true)
        let host = RedesignHost(view, size: CGSize(width: 700, height: 500))
        defer { host.close() }
        host.window.makeKeyAndOrderFront(nil)
        await host.settle { host.element("Approve once") != nil }
        let approve = try #require(host.element("Approve once"))
        let enabled = (approve.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue
        #expect(enabled == false)
        #expect(host.press(approve) == false)
        #expect(fake.responseCount == 0)
    }

    private func captureWindowBackedPNG(_ host: RedesignHost, to url: URL) throws {
        host.host.layoutSubtreeIfNeeded()
        host.host.displayIfNeeded()
        let width = 2880
        let height = 1800
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "CallerApprovalWindowCaptureTests", code: 1)
        }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / host.host.bounds.width, y: -CGFloat(height) / host.host.bounds.height)
        host.host.layer?.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CallerApprovalWindowCaptureTests", code: 2)
        }
        try data.write(to: url)
    }
}
