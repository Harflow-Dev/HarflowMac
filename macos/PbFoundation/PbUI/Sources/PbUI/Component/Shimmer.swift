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

import SwiftUI

// MARK: - Shimmer

/// A gentle brightness pulse for loading placeholders, applied via `.shimmering()`. Honours Reduce
/// Motion: when that accessibility setting is on, the content renders as a static fill with no
/// animation at all — the setting exists precisely to suppress this kind of movement, so a
/// placeholder that ignored it would be actively hostile to the person who turned it on.
private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBright = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1 : (isBright ? 1 : 0.55))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isBright = true
                }
            }
    }
}

public extension View {
    /// Applies the Monitor's shimmering-loading animation to `self` — meant for a translucent-primary
    /// placeholder shape (`SkeletonBlock`/`SkeletonRows`), but usable on any view. See
    /// `ShimmerModifier`'s doc for the Reduce Motion behaviour.
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - SkeletonBlock

/// One placeholder bar — a line of text, a badge, a block of body copy — filled with
/// `Color.primary` at 10% (visible on both the window and sidebar backgrounds, light and dark) and shimmering. `width: nil` (default) fills the available width, for a
/// placeholder standing in for a variable-width region.
public struct SkeletonBlock: View {
    public var width: CGFloat?
    public var height: CGFloat
    public var cornerRadius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat = 12, cornerRadius: CGFloat = 4) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.1))
            .frame(width: width, height: height)
            .shimmering()
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
                        Circle().fill(Color.primary.opacity(0.1)).frame(width: 20, height: 20).shimmering()
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
#Preview("SkeletonBlock") {
    VStack(alignment: .leading, spacing: 8) {
        SkeletonBlock(width: 220, height: 16)
        SkeletonBlock(width: 140, height: 12)
    }
    .padding()
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
