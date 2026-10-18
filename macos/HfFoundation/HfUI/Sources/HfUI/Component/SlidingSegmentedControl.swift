import SwiftUI

// MARK: - SlidingSegmentedControl

/// The design's tab switcher (SPEC §5.6): a `neutralFill` rounded-10 track, 32 pt high, holding
/// the options, with the selected one on a `selectedSegment` rounded-7 thumb carrying a 1 pt
/// shadow that slides to a newly clicked option. Each option is a real button carrying the
/// selected trait for VoiceOver; the selected label is semibold; under Reduce Motion — the system
/// setting or the presentation-only override — the thumb jumps instead of sliding.
public struct SlidingSegmentedControl<Value: Hashable>: View {
    public let options: [(value: Value, title: String)]
    @Binding public var selection: Value
    @Namespace private var thumb
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride

    public init(options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    private var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    public var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.hf(.body, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primaryText : Color.secondaryText)
                        .padding(.horizontal, HfRadius.Metrics.spacing14)
                        .padding(.vertical, HfRadius.Metrics.spacing4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: HfRadius.Metrics.segmentedThumbRadius)
                                    .fill(Color.selectedSegment)
                                    .shadow(
                                        color: Color.shadow.opacity(0.12),
                                        radius: HfRadius.Metrics.segmentedShadowRadius,
                                        y: HfRadius.Metrics.segmentedShadowRadius
                                    )
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(HfRadius.Metrics.spacing2)
        .frame(minHeight: HfRadius.Metrics.segmentedHeight)
        .background(
            RoundedRectangle(cornerRadius: HfRadius.Metrics.segmentedTrackRadius)
                .fill(Color.neutralFill)
        )
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
#Preview("Sliding segmented - Reduce Motion") { SlidingSegmentedPreview().environment(\.hfReduceMotionOverride, true) }
#endif
