//
//  Shimmer.swift
//  HfUI
//
//  Monitor piece 11: loading placeholders for content that is genuinely still being read (a fresh
//  listing, a task not yet in harflow's records, an event log still tailing) so those screens
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
///
/// Both run in Core Animation (`HfShimmerLayerView`). A `TimelineView` here kept every placeholder's
/// graph pending at 30 Hz, and each pending update re-measured the window root. The Reduce Motion
/// override still resolves as `shimmerReduceMotionOverride ?? accessibilityReduceMotion`.
///
/// Under Reduce Motion the content itself is hidden and a layer of the same `skeletonFill` tone takes
/// its place and pulses, so the view is meant for a flat `skeletonFill` placeholder (every caller
/// is). The layer clips itself to the placeholder's shape through `cornerRadius` or `maskPath`.
private struct ShimmerModifier: ViewModifier {
    let maskPath: Path?
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.shimmerReduceMotionOverride) private var reduceMotionOverride
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    func body(content: Content) -> some View {
        if reduceMotion {
            content
                .opacity(0)
                .overlay { decoration(.pulse) }
        } else {
            content
                .overlay { decoration(.sweep) }
                .clipped()
        }
    }

    private func decoration(_ mode: HfShimmerLayerView.Mode) -> some View {
        ShimmerLayer(mode: mode, maskPath: maskPath, cornerRadius: cornerRadius)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        modifier(ShimmerModifier(maskPath: nil, cornerRadius: 0))
    }

    /// `shimmering()` with the overlay clipped to rounded corners of `cornerRadius`, for a rounded placeholder
    /// (`SkeletonBlock`); the overlay is a layer view, which a SwiftUI `.clipShape` is not relied on to reach.
    func shimmering(cornerRadius: CGFloat) -> some View {
        modifier(ShimmerModifier(maskPath: nil, cornerRadius: cornerRadius))
    }

    /// `shimmering()` with the sheen (or the Reduce Motion pulse) limited to the filled area of
    /// `path`, given in the view's own coordinate space (origin top left). A layer-backed overlay
    /// cannot be relied on to follow a SwiftUI `.mask`, so a placeholder that is not a plain
    /// rectangle or rounded shape passes its outline here instead.
    func shimmering(maskedBy path: Path) -> some View {
        modifier(ShimmerModifier(maskPath: path, cornerRadius: 0))
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
            .shimmering(cornerRadius: cornerRadius)
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
