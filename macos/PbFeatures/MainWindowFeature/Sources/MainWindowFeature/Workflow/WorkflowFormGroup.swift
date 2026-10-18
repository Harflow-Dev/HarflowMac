import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowFormGroup

/// A §5.5 grouped-form container: `neutralFill`, radius 10, 36 pt rows with an inset hairline
/// between them. Presentation only — the rows' controls keep their own bindings and semantics.
struct WorkflowFormGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: PbRadius.Metrics.zero) { content() }
            .background(RoundedRectangle(cornerRadius: PbRadius.Metrics.formRadius).fill(Color.neutralFill))
            .clipShape(RoundedRectangle(cornerRadius: PbRadius.Metrics.formRadius))
    }
}

/// One §5.5 grouped row: label on the left, control on the right, 36 pt minimum height.
struct WorkflowFormRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PbRadius.Metrics.spacing8) {
                Text(label).font(.pb(.body)).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: PbRadius.Metrics.zero)
                control()
            }
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                Text(label).font(.pb(.body))
                control().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, PbRadius.Metrics.spacing4)
        }
        .padding(.leading, PbRadius.Metrics.formRowLeadingPadding)
        .padding(.trailing, PbRadius.Metrics.formRowTrailingPadding)
        .frame(minHeight: PbRadius.Metrics.formRowHeight)
        .accessibilityElement(children: .contain)
    }
}

/// An inset hairline between grouped rows (§5.5).
struct WorkflowFormDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: PbRadius.Metrics.hairlineStroke)
            .padding(.leading, PbRadius.Metrics.formRowLeadingPadding)
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
        HStack(spacing: PbRadius.Metrics.spacing4) {
            Text("\(value)")
                .font(.pb(.body))
                .monospacedDigit()
                .frame(minWidth: PbRadius.Metrics.compactValueWidth)
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
.padding(PbRadius.Metrics.spacing16)
.background(Color.cardFill)
    }
}

#Preview("Workflow grouped forms - light") {
    WorkflowFormPreview().frame(width: PbRadius.Metrics.formPreviewWidth).preferredColorScheme(.light)
}

#Preview("Workflow grouped forms - dark, narrow") {
    WorkflowFormPreview().frame(width: PbRadius.Metrics.workflowInspectorMinimumWidth).preferredColorScheme(.dark)
}
#endif
