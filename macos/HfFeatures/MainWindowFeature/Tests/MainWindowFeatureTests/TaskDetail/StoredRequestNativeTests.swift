import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

extension ObservationHostedTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenNativeStoredRequest_whenMounted_thenLiteralUnicodeIsReadOnlySelectableAndWrapped(scheme: ColorScheme) async throws {
        // given
        let text = "  café 👩🏽‍💻\n\n\t中🙂  \n" + String(repeating: "Bounded literal request text wraps within its reading region. ", count: 20)
        let model = NativeRequestFixture(text: text)
        let fixture = ObservationHost(NativeRequestSurface(model: model), width: 396, height: 360, appearance: scheme)
        defer { fixture.close() }
        try await fixture.requireForeground()
        await waitUntil {
            guard let native = nativeRequest(in: fixture), let scroll = native.enclosingScrollView else { return false }
            return native.string == text && scroll.contentView.bounds.width > 0 && scroll.contentView.bounds.height > 0
                && native.frame.height > scroll.contentView.bounds.height
        }
        // when / then
        let native = try #require(nativeRequest(in: fixture))
        #expect(native.string == text)
        #expect(!native.isEditable && native.isSelectable)
        #expect(native.accessibilityValue() == text)
        #expect(native.isHorizontallyResizable == false)
        let scroll = try #require(native.enclosingScrollView)
        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.bounds.width > 0 && scroll.bounds.height > 0)
        #expect(scroll.bounds.width.isFinite && scroll.bounds.height.isFinite)
        #expect(native.frame.width.isFinite && native.frame.height.isFinite)
        #expect(scroll.bounds.height <= 180 && scroll.bounds.width <= 396)
        #expect(native.frame.height > scroll.contentView.bounds.height)
        #expect(native.frame.width <= scroll.contentView.bounds.width + 1)
    }

    @Test func givenConsumedReadIntent_whenUnchangedTextRendersAndRemounts_thenPeerFocusAndSelectionArePreserved() async throws {
        // given
        let model = NativeRequestFixture(text: "  literal request\nsecond line  ")
        let intent = StoredRequestFocusIntent()
        model.intent = intent
        let fixture = ObservationHost(NativeRequestSurface(model: model), width: 396, height: 360)
        defer { fixture.close() }
        try await fixture.requireForeground()
        await waitUntil { nativeRequest(in: fixture).map { fixture.window.firstResponder === $0 } == true && model.intent == nil }
        let native = try #require(nativeRequest(in: fixture))
        #expect(fixture.window.firstResponder === native)
        #expect(!intent.isPending && model.completed == 1)
        native.setSelectedRange(NSRange(location: 2, length: 7))
        let selection = native.selectedRange()
        let peer = try #require(nativeViews(fixture.host).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "request-peer" })
        #expect(fixture.window.makeFirstResponder(peer))
        let peerResponder = try #require(fixture.window.firstResponder)
        #expect(peerResponder !== native)
        // when
        model.revision += 1
        await waitUntil { fixture.find("Revision 1") != nil }
        // then
        #expect(native.selectedRange() == selection)
        #expect(fixture.window.firstResponder === peerResponder)
        model.showText = false
        await waitUntil { nativeRequest(in: fixture) == nil }
        model.showText = true
        await waitUntil { nativeRequest(in: fixture) != nil }
        #expect(fixture.window.firstResponder === peerResponder)
        #expect(model.completed == 1 && model.intent == nil)
    }

    @Test func givenPendingIntentInInactiveWindow_whenTargetIsRemoved_thenReattachmentCannotReplayCancelledIntent() async throws {
        // given
        let model = NativeRequestFixture(text: "Pending native text")
        model.showText = false
        let fixture = ObservationHost(NativeRequestSurface(model: model), width: 396, height: 360)
        defer { fixture.close() }
        try await fixture.requireForeground()
        let peer = try #require(nativeViews(fixture.host).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "request-peer" })
        #expect(fixture.window.makeFirstResponder(peer))
        fixture.window.orderOut(nil)
        #expect(!fixture.window.isKeyWindow)
        let pending = StoredRequestFocusIntent()
        model.intent = pending
        model.showText = true
        await waitUntil { nativeRequest(in: fixture) != nil }
        #expect(pending.isPending)
        // when
        model.showText = false
        await waitUntil { nativeRequest(in: fixture) == nil && !pending.isPending && model.intent == nil }
        // then
        #expect(!pending.isPending)
        try await fixture.requireForeground()
        #expect(fixture.window.makeFirstResponder(peer))
        let peerResponder = try #require(fixture.window.firstResponder)
        model.showText = true
        await waitUntil { nativeRequest(in: fixture) != nil }
        #expect(fixture.window.firstResponder === peerResponder)
        #expect(model.intent == nil)
    }

    private func nativeRequest(in fixture: ObservationHost) -> NSTextView? {
        nativeViews(fixture.host).compactMap { $0 as? StoredRequestScrollView }.first?.requestTextView
    }

    private func nativeViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(nativeViews) }
}

@Observable @MainActor
private final class NativeRequestFixture {
    var text: String
    var intent: StoredRequestFocusIntent?
    var showText = true
    var revision = 0
    var completed = 0
    init(text: String) { self.text = text }
}

@MainActor
private struct NativeRequestSurface: View {
    let model: NativeRequestFixture
    var body: some View {
        VStack {
            if model.showText {
                StoredRequestText(text: model.text, focusIntent: model.intent) { token in
                    if model.intent === token { model.intent = nil; model.completed += 1 }
                }.frame(maxHeight: 180)
            }
            NativeRequestPeer().frame(height: 24)
            Text("Revision \(model.revision)")
        }.padding(24)
    }
}

private struct NativeRequestPeer: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSTextField {
        let field = NSTextField(string: "Peer focus")
        field.identifier = NSUserInterfaceItemIdentifier("request-peer")
        return field
    }

    func updateNSView(_: NSTextField, context _: Context) {}
}
