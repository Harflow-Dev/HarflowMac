import SwiftUI

// MARK: - SlidingSegmentedControl

/// The design's tab switcher: a dark rounded track holding the options, with the selected one on a
/// lighter "thumb" that slides to a newly clicked option. Each option is a real button carrying the
/// selected trait for VoiceOver; under Reduce Motion the thumb jumps instead of sliding.
public struct SlidingSegmentedControl<Value: Hashable>: View {
    public let options: [(value: Value, title: String)]
    @Binding public var selection: Value
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.pb(.body, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: PbRadius.button - 1)
                                    .fill(Color.selectedSegment)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: PbRadius.button + 1).fill(Color.pillFill))
    }
}

#if DEBUG
private struct SlidingSegmentedPreview: View {
    @State private var tab = "Activity"

    var body: some View {
        SlidingSegmentedControl(options: ["Activity", "Summary", "Prompt"].map { ($0, $0) }, selection: $tab)
            .padding()
            .background(Color.windowBG)
    }
}

#Preview("Sliding segmented - light") { SlidingSegmentedPreview().preferredColorScheme(.light) }
#Preview("Sliding segmented - dark") { SlidingSegmentedPreview().preferredColorScheme(.dark) }
#endif
