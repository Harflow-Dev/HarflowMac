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

    init(request: CallerApprovalRequest) { self.request = request }

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        CallerApprovalPage(requests: [request], total: 1)
    }

    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest { request }

    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        responseCount += 1
        return request
    }
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
        "interaction_owner": .string(owner),
        "disposition": .string("pending"),
        "delivery": .string("pending"),
        "execution_outcome": .string("unknown"),
        "tool_name": .string("Bash"),
        "cwd": .string("/tmp/polybridge-capture"),
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
            .appendingPathComponent(configuredRoot == nil ? "pb61-ui-captures-\(UUID().uuidString)" : "")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let cases: [(String, ColorScheme?, String)] = [
            ("caller-approval-light", .light, "monitor"),
            ("caller-approval-dark", .dark, "monitor"),
            ("caller-approval-caller-owned", .light, "caller")
        ]
        for (name, scheme, owner) in cases {
            let request = captureRequest(owner: owner)
            let fake = CallerApprovalCaptureFake(request: request)
            let controller = CallerApprovalController(useCase: fake)
            await controller.selectTarget(taskID: "task-capture", workflowRunID: nil)
            await controller.inspect(request)
            #expect(controller.isCurrentDetail)
            #expect(controller.detail?.raw["action"]?.rendered(pretty: true).contains("long-command-scroll-probe") == true)

            let view = CallerApprovalCard(controller: controller)
                .frame(width: 620, alignment: .leading)
                .preferredColorScheme(scheme)
            let host = RedesignHost(view, size: CGSize(width: 1440, height: 900), appearance: scheme)
            defer { host.close() }
            host.window.makeKeyAndOrderFront(nil)
            await host.settle { host.hasRenderedInk }
            #expect(host.hasRenderedInk)
            if owner == "monitor" {
                let approve = try #require(host.element("Approve once"))
                let reject = try #require(host.element("Reject"))
                #expect(controller.isCurrentDetail)
                #expect(approve.responds(to: NSSelectorFromString("accessibilityPerformPress")))
                #expect(reject.responds(to: NSSelectorFromString("accessibilityPerformPress")))
            } else {
                #expect(host.element("Approve once") == nil)
                #expect(host.element("Reject") == nil)
            }
            let scrollViews = host.descendants.compactMap { $0 as? NSScrollView }
            #expect(scrollViews.contains { scroll in
                scroll.hasHorizontalScroller && (scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width
            })
            try captureWindowBackedPNG(host, to: root.appendingPathComponent(name + ".png"))
            if owner == "monitor" {
                let approve = try #require(host.element("Approve once"))
                #expect(host.press(approve))
                await host.settle { fake.responseCount == 1 }
                #expect(fake.responseCount == 1)
            }
        }
        let captures = try FileManager.default
.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        #expect(captures.count == 3)
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
