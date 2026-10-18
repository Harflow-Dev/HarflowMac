import SwiftUI

// MARK: - ActivityCard

/// A rounded, opaque container on `cardFill` with a hairline `cardBorder` (SPEC §5.4), used for
/// grouped activity. The padded single-content API is unchanged: it owns its 10 × 14 padding, so
/// a caller supplies one content block. The hairline border is overridable — a needs-attention
/// card (§6.8) passes the palette's 35% warning tone; `nil` (the default) keeps `cardBorder`.
/// For grouped rows, dividers and edge-to-edge diff bodies, use `GroupedActivityCard` with the row
/// primitives below.
public struct ActivityCard<Content: View>: View {
    private let border: Color?
    private let content: Content

    public init(border: Color? = nil, @ViewBuilder content: () -> Content) {
        self.border = border
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PbRadius.Metrics.cardPaddingVertical)
            .padding(.horizontal, PbRadius.Metrics.cardPaddingHorizontal)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.cardFill))
            .overlay(
                RoundedRectangle(cornerRadius: PbRadius.card)
                    .stroke(border ?? Color.cardBorder, lineWidth: PbRadius.Metrics.hairlineStroke)
            )
    }
}

// MARK: - GroupedActivityCard

/// The unpadded, clipped grouped-card container: `cardFill`, hairline `cardBorder`, radius 12, and
/// content clipped to that radius so full-width rows, dividers and diff bodies run edge to edge.
/// It cannot inspect its children — each `ActivityCardRow` owns its own 10 × 14 padding, and any
/// count or summary the events do not carry is omitted, never invented.
public struct GroupedActivityCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.zero) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.cardFill))
            .clipShape(RoundedRectangle(cornerRadius: PbRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: PbRadius.card)
                    .stroke(Color.cardBorder, lineWidth: PbRadius.Metrics.hairlineStroke)
            )
    }
}

// MARK: - ActivityCardRow

/// One grouped card row: it owns the row's 10 × 14 padding, so the card body itself stays unpadded
/// and dividers and diff bodies can run edge to edge. Generic content; the feature's own activity
/// builders decide what a row shows.
public struct ActivityCardRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PbRadius.Metrics.activityRowPaddingVertical)
            .padding(.horizontal, PbRadius.Metrics.activityRowPaddingHorizontal)
    }
}

// MARK: - ActivityCardDivider

/// A full-width hairline between grouped-card rows, edge to edge — the surrounding card clips it.
public struct ActivityCardDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: PbRadius.Metrics.hairlineStroke)
    }
}

// MARK: - ActivityDiffBody

/// An edge-to-edge diff body (SPEC §5.4): unpadded on `codeFill`, so a diff line's
/// `diffAddedFill`/`diffRemovedFill` background reaches both card edges. The caller supplies the
/// lines; any `+N −M` the events do not carry is omitted, never invented.
public struct ActivityDiffBody<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.zero) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codeFill)
    }
}

// MARK: - ActivityDiffLine

/// One diff line: its marker and text in the monospaced `.secondary` style, on the line's own
/// background — `diffAddedFill` for added, `diffRemovedFill` for removed, transparent for context.
public struct ActivityDiffLine: View {
    /// A diff line's kind, which picks its background.
    public enum Kind {
        case added
        case removed
        case context
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    private var background: Color? {
        switch kind {
        case .added: .diffAddedFill
        case .removed: .diffRemovedFill
        case .context: nil
        }
    }

    public var body: some View {
        Text(text)
            .font(.pb(.secondary, design: .monospaced))
            .foregroundStyle(Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PbRadius.Metrics.activityRowPaddingHorizontal)
            .padding(.vertical, PbRadius.Metrics.spacing2)
            .background(background ?? Color.shadow.opacity(0))
    }
}

#if DEBUG
#Preview("ActivityCard - light") {
    ActivityCardPreview().preferredColorScheme(.light)
}

#Preview("ActivityCard - dark") {
    ActivityCardPreview().preferredColorScheme(.dark)
}

private struct ActivityCardPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            ActivityCard {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                    Text("Read 3 files").font(.pb(.body, weight: .medium))
                    Text("00:25 – 01:09").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                }
            }
            ActivityCard(border: Color.warningBorder) {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                    Text("Needs attention").font(.pb(.body, weight: .medium)).foregroundStyle(Color.warningFG)
                    Text("Implementation reached its attempt limit.")
                        .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
                }
            }
        }
        .padding()
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
        .background(Color.windowBG)
    }
}

/// Dummy rows for the grouped/diff previews only — explicitly invented sample content, not
/// production data; nothing in the real activity builders derives from it.
private struct ActivityGroupedPreview: View {
    var body: some View {
        GroupedActivityCard {
            ActivityCardRow {
                HStack(spacing: PbRadius.Metrics.spacing8) {
                    Image(systemName: "doc.text")
                        .font(.pb(.body))
                        .foregroundStyle(Color.secondaryText)
                    Text("Edited Sources/App.swift")
                        .font(.pb(.body, weight: .medium))
                    Spacer()
                    Text("example.swift").font(.pb(.secondary)).foregroundStyle(Color.tertiaryText)
                }
            }
            ActivityCardDivider()
            ActivityDiffBody {
                ActivityDiffLine(kind: .context, text: " func update() {")
                ActivityDiffLine(kind: .removed, text: "-    let value = 1")
                ActivityDiffLine(kind: .added, text: "+    let value = 2")
                ActivityDiffLine(kind: .context, text: " }")
            }
            ActivityCardDivider()
            ActivityCardRow {
                Text("Ran 2 commands")
                    .font(.pb(.body, weight: .medium))
            }
        }
        .padding()
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
        .background(Color.windowBG)
    }
}

#Preview("GroupedActivityCard - light") {
    ActivityGroupedPreview().preferredColorScheme(.light)
}

#Preview("GroupedActivityCard - dark") {
    ActivityGroupedPreview().preferredColorScheme(.dark)
}
#endif
