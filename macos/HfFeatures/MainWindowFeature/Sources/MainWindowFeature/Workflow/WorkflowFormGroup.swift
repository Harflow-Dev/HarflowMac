import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowFormGroup

/// A §5.5 grouped-form container: `neutralFill`, radius 10, 36 pt rows with an inset hairline
/// between them. Presentation only — the rows' controls keep their own bindings and semantics.
struct WorkflowFormGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: HfRadius.Metrics.zero) { content() }
            .background(RoundedRectangle(cornerRadius: HfRadius.Metrics.formRadius).fill(Color.neutralFill))
            .clipShape(RoundedRectangle(cornerRadius: HfRadius.Metrics.formRadius))
    }
}

/// One §5.5 grouped row: label on the left, control on the right, 36 pt minimum height.
struct WorkflowFormRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HfRadius.Metrics.spacing8) {
                Text(label).font(.hf(.body)).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: HfRadius.Metrics.zero)
                control()
            }
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                Text(label).font(.hf(.body))
                control().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, HfRadius.Metrics.spacing4)
        }
        .padding(.leading, HfRadius.Metrics.formRowLeadingPadding)
        .padding(.trailing, HfRadius.Metrics.formRowTrailingPadding)
        .frame(minHeight: HfRadius.Metrics.formRowHeight)
        .accessibilityElement(children: .contain)
    }
}

/// An inset hairline between grouped rows (§5.5).
struct WorkflowFormDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: HfRadius.Metrics.hairlineStroke)
            .padding(.leading, HfRadius.Metrics.formRowLeadingPadding)
            .accessibilityHidden(true)
    }
}

/// The compact `− value +` stepper of §5.5: the native stepper with a monospaced value, its
/// binding and range untouched.
struct WorkflowCompactStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing4) {
            Text("\(value)")
                .font(.hf(.body))
                .monospacedDigit()
                .frame(minWidth: HfRadius.Metrics.compactValueWidth)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
            Stepper(label, value: $value, in: range)
                .labelsHidden()
                .fixedSize()
                .accessibilityValue(Text("\(value)"))
        }
    }
}

#if DEBUG
private struct WorkflowFormPreview: View {
    @State private var attempts = 3
    var body: some View {
        WorkflowFormGroup {
            WorkflowFormRow(label: "Decision attempts") {
                WorkflowCompactStepper(label: "Decision attempts", value: $attempts, range: 1 ... 10)
            }
            WorkflowFormDivider()
            WorkflowFormRow(label: "Agent") {
                Picker("Agent", selection: .constant("codex")) {
                    Text("Codex").tag("codex")
                    Text("Claude").tag("claude")
                }
.labelsHidden()
.pickerStyle(.menu)
            }
        }
.padding(HfRadius.Metrics.spacing16)
.background(Color.cardFill)
    }
}

#Preview("Workflow grouped forms - light") {
    WorkflowFormPreview().frame(width: HfRadius.Metrics.formPreviewWidth).preferredColorScheme(.light)
}

#Preview("Workflow grouped forms - dark, narrow") {
    WorkflowFormPreview().frame(width: HfRadius.Metrics.workflowInspectorMinimumWidth).preferredColorScheme(.dark)
}
#endif
