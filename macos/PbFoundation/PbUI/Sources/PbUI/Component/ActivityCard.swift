import SwiftUI

// MARK: - ActivityCard

/// A rounded container on `cardFill` with a hairline `cardBorder`, used for grouped activity.
public struct ActivityCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.cardFill))
            .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(Color.cardBorder, lineWidth: 1))
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
        ActivityCard {
            VStack(alignment: .leading, spacing: 2) {
                Text("Read 3 files").font(.pb(.body, weight: .medium))
                Text("00:25 – 01:09").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
        .padding()
        .frame(width: 320)
        .background(Color.windowBG)
    }
}
#endif
