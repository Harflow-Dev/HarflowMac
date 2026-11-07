//
//  LayerMotionViews.swift
//  MainWindowFeature
//
//  SwiftUI wrappers for the layer-driven indicators in `LayerMotion.swift`. Each resolves Reduce
//  Motion the way the views it replaces did (the presentation-only override wins over the system
//  setting) and passes it down as a flag; the layer view adds or removes its animation only when
//  that flag, or the window, changes.
//

import AppKit
import HfUI
import SwiftUI

// MARK: - FeedReduceMotion

/// Resolves Reduce Motion from the environment, live.
private struct FeedReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.hfReduceMotionOverride) private var forced

    var isOn: Bool { HfMotion.reduceMotion(override: forced, system: system) }
}

// MARK: - StreamingCaretLayer

/// The streaming caret glyph with a Core Animation blink. Decorative: hidden from accessibility.
struct StreamingCaretLayer: NSViewRepresentable {
    let blinks: Bool

    func makeNSView(context _: Context) -> LayerCaretView {
        let view = LayerCaretView(font: NSFont.monospacedSystemFont(ofSize: HfTextStyle.body.pointSize, weight: .regular),
                                  color: Color.secondaryText)
        view.animates = blinks
        return view
    }

    func updateNSView(_ view: LayerCaretView, context _: Context) {
        if view.animates != blinks { view.animates = blinks }
    }

    func sizeThatFits(_: ProposedViewSize, nsView: LayerCaretView, context _: Context) -> CGSize? { nsView.glyphSize }
}

// MARK: - FeedRunningSpinner

/// The tool row and tool group card's running spinner: `RunningSpinner`'s look (accent arc turning
/// once a second on a 20% track) drawn in Core Animation. Exposes "Running", as `RunningSpinner` does.
struct FeedRunningSpinner: View {
    var size: CGFloat = HfRadius.Metrics.spinnerSize
    private let reduceMotion = FeedReduceMotion()

    var body: some View {
        LayerSpinner(spec: LayerSpinnerSpec(diameter: size,
                                            lineWidth: HfRadius.Metrics.spinnerStroke,
                                            arcFraction: 0.3,
                                            period: 1,
                                            ringColor: Color.runningFG,
                                            ringOpacity: 0.2,
                                            arcColor: Color.runningFG),
                     animates: !reduceMotion.isOn)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel("Running")
    }
}

// MARK: - LayerSpinner

/// The representable under `FeedRunningSpinner` and `TranscriptWorkingGlyph`.
struct LayerSpinner: NSViewRepresentable {
    let spec: LayerSpinnerSpec
    let animates: Bool

    func makeNSView(context _: Context) -> LayerSpinnerView {
        let view = LayerSpinnerView(spec: spec)
        view.animates = animates
        return view
    }

    func updateNSView(_ view: LayerSpinnerView, context _: Context) {
        if view.spec != spec { view.spec = spec }
        if view.animates != animates { view.animates = animates }
    }

    func sizeThatFits(_: ProposedViewSize, nsView: LayerSpinnerView, context _: Context) -> CGSize? {
        CGSize(width: nsView.spec.side, height: nsView.spec.side)
    }
}

// MARK: - FeedPulseDot

/// The live-step dot: fades between full and 30% opacity every 0.8 seconds, in Core Animation.
/// Hidden from accessibility, as the dots it replaces were.
struct FeedPulseDot: View {
    let diameter: CGFloat
    private let reduceMotion = FeedReduceMotion()

    var body: some View {
        LayerPulseDot(diameter: diameter, color: Color.liveDot, animates: !reduceMotion.isOn)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

// MARK: - LayerPulseDot

/// The representable under `FeedPulseDot`.
struct LayerPulseDot: NSViewRepresentable {
    let diameter: CGFloat
    let color: Color
    let animates: Bool

    func makeNSView(context _: Context) -> LayerPulseDotView {
        let view = LayerPulseDotView(diameter: diameter, color: color)
        view.animates = animates
        return view
    }

    func updateNSView(_ view: LayerPulseDotView, context _: Context) {
        view.diameter = diameter
        view.color = color
        if view.animates != animates { view.animates = animates }
    }

    func sizeThatFits(_: ProposedViewSize, nsView: LayerPulseDotView, context _: Context) -> CGSize? {
        CGSize(width: nsView.diameter, height: nsView.diameter)
    }
}

#if DEBUG
private struct LayerMotionPreview: View {
    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing16) {
            StreamingCaretLayer(blinks: true)
            FeedRunningSpinner(size: HfRadius.Metrics.spacing12)
            TranscriptWorkingGlyph()
            FeedPulseDot(diameter: HfRadius.Metrics.spacing8)
        }
        .padding(HfRadius.Metrics.spacing16)
        .background(Color.windowBG)
    }
}

#Preview("Layer motion - light") { LayerMotionPreview().environment(\.hfReduceMotionOverride, false).preferredColorScheme(.light) }
#Preview("Layer motion - dark") { LayerMotionPreview().environment(\.hfReduceMotionOverride, false).preferredColorScheme(.dark) }
#Preview("Layer motion, Reduce Motion - light") { LayerMotionPreview().environment(\.hfReduceMotionOverride, true).preferredColorScheme(.light) }
#Preview("Layer motion, Reduce Motion - dark") { LayerMotionPreview().environment(\.hfReduceMotionOverride, true).preferredColorScheme(.dark) }
#endif
