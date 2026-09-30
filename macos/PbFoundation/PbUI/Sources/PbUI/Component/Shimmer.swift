//
//  Shimmer.swift
//  PbUI
//
//  Monitor piece 11: loading placeholders for content that is genuinely still being read (a fresh
//  listing, a task not yet in polybridge's records, an event log still tailing) so those screens
//  show something other than a blank view or a bare "Loading…" while a `recompute()` is in flight.
//  `.shimmering()` is the animation primitive; `SkeletonBlock`/`SkeletonRows` are the placeholder
//  shapes screens compose into a header/list/region skeleton.
//

import AppKit
import SwiftUI

// MARK: - Skeleton colours

public extension Color {
    /// A loading placeholder's fill: black at 6% in light mode, white at 7% in dark (the design's
    /// shimmer artboards), so it reads on the window, sidebar and card backgrounds alike.
    static let skeletonFill = Color(nsColor: NSColor(name: "skeletonFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.06)
    })

    /// The sheen that sweeps across a placeholder: a white highlight, strong on light, faint on dark.
    static let skeletonSheen = Color(nsColor: NSColor(name: "skeletonSheen") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 1, alpha: 0.75)
    })
}

// MARK: - Shimmer

/// The loading animation, applied via `.shimmering()`: a highlight sweeping left to right every
/// 1.4 s. Under Reduce Motion there is no movement — the placeholder pulses its opacity slowly
/// (1.6 s) instead, so it still reads as "loading" without anything travelling across the screen.
private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shimmerReduceMotionOverride) private var reduceMotionOverride
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @State private var phase: CGFloat = -1
    @State private var isDim = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(isDim ? 0.55 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { isDim = true }
                }
        } else {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .skeletonSheen, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width)
                            .offset(x: phase * proxy.size.width)
                    }
                    .allowsHitTesting(false)
                }
                .clipped()
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
    }
}

public extension EnvironmentValues {
    /// Forces the shimmer's Reduce Motion behaviour on or off (`nil`: follow the system setting).
    /// The system value is read-only, so this is how a preview shows the pulse.
    @Entry var shimmerReduceMotionOverride: Bool?
}

public extension View {
    /// Applies the Monitor's loading shimmer to `self` — meant for a `skeletonFill` placeholder
    /// shape (`SkeletonBlock`/`SkeletonRows`), but usable on any view. See `ShimmerModifier` for the
    /// Reduce Motion behaviour.
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - SkeletonBlock

/// One placeholder bar — a line of text, a button, a block of body copy — in `skeletonFill`, with
/// the shimmer clipped to its own rounded shape. `width: nil` (default) fills the available width,
/// for a placeholder standing in for a variable-width region.
public struct SkeletonBlock: View {
    public var width: CGFloat?
    public var height: CGFloat
    public var cornerRadius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat = 12, cornerRadius: CGFloat = 6) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.skeletonFill)
            .shimmering()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .frame(width: width, height: height)
    }
}

// MARK: - SkeletonRows

/// A stack of row-shaped placeholders — a badge circle plus a title/subtitle pair, repeated
/// `count` times — standing in for a list (the sidebar's task tree, a timeline) while it is still
/// loading. Alternating title widths keep the placeholder from reading as one literal repeated row.
public struct SkeletonRows: View {
    public var count: Int
    public var showsBadge: Bool

    public init(count: Int = 4, showsBadge: Bool = true) {
        self.count = count
        self.showsBadge = showsBadge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0 ..< count, id: \.self) { index in
                HStack(spacing: 8) {
                    if showsBadge {
                        SkeletonBlock(width: 20, height: 20, cornerRadius: 10)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(width: index.isMultiple(of: 2) ? 190 : 140, height: 12)
                        SkeletonBlock(width: 90, height: 10)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("SkeletonBlock - light") {
    VStack(alignment: .leading, spacing: 8) {
        SkeletonBlock(width: 220, height: 16)
        SkeletonBlock(width: 140, height: 12)
    }
    .padding()
    .background(Color.windowBG)
    .preferredColorScheme(.light)
}

#Preview("SkeletonBlock - dark") {
    VStack(alignment: .leading, spacing: 8) {
        SkeletonBlock(width: 220, height: 16)
        SkeletonBlock(width: 140, height: 12)
    }
    .padding()
    .background(Color.windowBG)
    .preferredColorScheme(.dark)
}

#Preview("SkeletonRows") {
    SkeletonRows()
        .padding()
        .frame(width: 280)
}

#Preview("SkeletonRows - no badge") {
    SkeletonRows(count: 3, showsBadge: false)
        .padding()
        .frame(width: 400)
}
#endif
