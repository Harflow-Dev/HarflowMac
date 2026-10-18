import PbUI
import SwiftUI

// MARK: - WorkflowConditionPill

/// A bounded, decorative edge caption. Full condition text stays in the edge's existing
/// tooltip, accessibility label and inspector; this single line cannot cover nearby nodes.
struct WorkflowConditionPill: View {
    let condition: String

    var body: some View {
        Text(condition.replacingOccurrences(of: "\n", with: " "))
            .font(.pb(.secondary))
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: PbRadius.Metrics.workflowConditionPillMaximumWidth
                - PbRadius.Metrics.workflowConditionPillHorizontalPadding * 2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, PbRadius.Metrics.workflowConditionPillHorizontalPadding)
            .padding(.vertical, PbRadius.Metrics.workflowConditionPillVerticalPadding)
            .background(Capsule().fill(Color.cardFill))
            .overlay(Capsule().stroke(Color.hairline, lineWidth: PbRadius.Metrics.hairlineStroke))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Condition pill - light") {
    WorkflowConditionPill(condition: "Continue when the implementation is complete").preferredColorScheme(.light)
}

#Preview("Condition pill - dark, multiline") {
    WorkflowConditionPill(condition: "Continue when the implementation is complete.\nOtherwise return to the planning step.")
        .preferredColorScheme(.dark)
}
#endif
