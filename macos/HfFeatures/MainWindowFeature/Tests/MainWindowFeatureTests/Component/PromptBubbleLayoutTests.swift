import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct PromptBubbleLayoutTests {
    @Test func givenLongText_whenAvailableWidthChanges_thenBubbleCapsAndAlignsTrailing() async throws {
        let text = String(repeating: "A long prompt wraps naturally within the available bubble width. ", count: 12)

        for width in [CGFloat(320), 560, 900] {
            let probe = PromptBubbleLayoutGeometryProbe()
            let host = NSHostingView(rootView: PromptBubbleLayoutGeometryRoot(text: text, width: width, probe: probe))
            let window = open(host, width: width)
            defer { window.contentView = nil; window.close() }

            await waitUntil(timeout: 3) {
                host.layoutSubtreeIfNeeded()
                return probe.frame.height > 0
            }
            let frame = try #require(probe.frame.height > 0 ? probe.frame : nil)
            let expectedWidth = min(width * 0.75, 420)
            #expect(abs(frame.width - expectedWidth) <= 1, "width=\(width): bubble width \(frame.width) != cap \(expectedWidth)")
            #expect(abs(frame.maxX - width) <= 1, "width=\(width): bubble trailing edge \(frame.maxX) != container \(width)")
            #expect(frame.height > 60, "width=\(width): long prompt should wrap into multiple lines")
        }
    }

    @Test func givenShortText_whenAvailableWidthIsWide_thenBubbleKeepsNaturalSingleLineWidth() async throws {
        let text = "Fix the flaky login test."
        let width: CGFloat = 900
        let probe = PromptBubbleLayoutGeometryProbe()
        let host = NSHostingView(rootView: PromptBubbleLayoutGeometryRoot(text: text, width: width, probe: probe))
        let window = open(host, width: width)
        defer { window.contentView = nil; window.close() }

        await waitUntil(timeout: 3) {
            host.layoutSubtreeIfNeeded()
            return probe.frame.height > 0
        }
        let frame = try #require(probe.frame.height > 0 ? probe.frame : nil)
        #expect(frame.width < 420)
        #expect(frame.height < 60)
        #expect(abs(frame.maxX - width) <= 1)
    }

    @Test func givenHuggingChild_whenAvailableWidthIsFinite_thenChildStaysWithinCapAndTrailingAligned() async throws {
        let probe = PromptBubbleLayoutGeometryProbe()
        let width: CGFloat = 320
        let host = NSHostingView(rootView: PromptBubbleLayoutGeometryRoot(
            text: "A hugging child remains max-content.", width: width, expandsText: false, probe: probe
        ))
        let window = open(host, width: width)
        defer { window.contentView = nil; window.close() }

        await waitUntil(timeout: 3) {
            host.layoutSubtreeIfNeeded()
            return probe.frame.height > 0
        }
        let frame = try #require(probe.frame.height > 0 ? probe.frame : nil)
        #expect(frame.width <= width * 0.75)
        #expect(abs(frame.maxX - width) <= 1)
    }

    @Test func givenOrdinaryAndQueuedPrompts_whenTextMatches_thenHostedHeightMatches() async throws {
        let text = String(repeating: "Review the result and report any issue. ", count: 5)
        let width: CGFloat = 560
        let ordinary = NSHostingView(rootView: PromptBubbleView(text: text).frame(width: width, alignment: .trailing))
        let queued = NSHostingView(rootView: PromptBubbleView(text: text, isPending: true).frame(width: width, alignment: .trailing))
        let window = open(ordinary, width: width)
        defer { window.contentView = nil; window.close() }
        queued.layoutSubtreeIfNeeded()
        ordinary.layoutSubtreeIfNeeded()

        #expect(abs(ordinary.fittingSize.height - queued.fittingSize.height) <= 1)
    }

    @Test func givenBubbleLayout_whenProposalIsUnboundedOrZero_thenMeasurementStaysFinite() {
        let text = String(repeating: "Natural prompt width remains finite. ", count: 10)
        func measure(_ proposal: ProposedViewSize) -> CGSize {
            let host = NSHostingView(rootView: PromptBubbleProposalLayout(proposal: proposal) {
                PromptBubbleTrailingLayout {
                    Text(text).padding(.horizontal, 14).padding(.vertical, 10)
                }
            })
            return host.fittingSize
        }

        let natural = measure(.unspecified)
        let unbounded = measure(.infinity)
        let zero = measure(.zero)

        #expect(natural.width.isFinite && natural.height.isFinite)
        #expect(unbounded.width.isFinite && unbounded.height.isFinite)
        #expect(unbounded.width <= 420 && unbounded.height > 0)
        #expect(zero.width.isFinite && zero.height.isFinite)
        #expect(zero.width == 0)
    }

    private func open(_ host: NSView, width: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }
}

@MainActor private final class PromptBubbleLayoutGeometryProbe: ObservableObject {
    @Published var frame: CGRect = .zero
}

@MainActor private struct PromptBubbleLayoutGeometryRoot: View {
    let text: String
    let width: CGFloat
    var expandsText = true
    let probe: PromptBubbleLayoutGeometryProbe

    var body: some View {
        PromptBubbleTrailingLayout {
            Text(text)
                .font(.system(size: 16))
                .frame(maxWidth: expandsText ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PromptBubbleLayoutFramePreference.self,
                                           value: geometry.frame(in: .named("bubble-layout")))
                })
        }
        .frame(width: width, height: 500, alignment: .topLeading)
        .coordinateSpace(name: "bubble-layout")
        .onPreferenceChange(PromptBubbleLayoutFramePreference.self) { probe.frame = $0 }
    }
}

private struct PromptBubbleProposalLayout: Layout {
    let proposal: ProposedViewSize

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: proposal)
    }
}

private struct PromptBubbleLayoutFramePreference: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
