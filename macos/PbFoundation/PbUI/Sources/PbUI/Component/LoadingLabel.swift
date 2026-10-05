import SwiftUI

// MARK: - LoadingLabel

/// A compact loading indicator with the same footprint as a quiet action label.
public struct LoadingLabel: View {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: 6) {
            RunningSpinner(size: 12, tint: .secondaryText).accessibilityHidden(true)
            Text(text).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

#if DEBUG
#Preview { LoadingLabel("Loading tasks…").padding() }
#endif
