import SwiftUI

// MARK: - GroupedForm

/// A grouped form container (SPEC §5.5): a `neutralFill` rounded-10 panel holding
/// `GroupedFormRow`s separated by `GroupedFormDivider`s. A compositional wrapper around
/// caller-supplied native controls — it adds no field behaviour, bounds, commit handling or
/// selection semantics of its own.
public struct GroupedForm<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HfRadius.Metrics.formRadius).fill(Color.neutralFill))
        .clipShape(RoundedRectangle(cornerRadius: HfRadius.Metrics.formRadius))
    }
}

// MARK: - GroupedFormRow

/// One grouped form row: the label on the left, a caller-supplied (native) control on the right,
/// at least 36 pt high for accessibility. The row lays out only; the control keeps its own logic.
public struct GroupedFormRow<Control: View>: View {
    public let title: String
    private let control: Control

    public init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    public var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            Text(title)
                .font(.hf(.body))
                .foregroundStyle(Color.primaryText)
            Spacer(minLength: HfRadius.Metrics.spacing8)
            control
        }
        .padding(.leading, HfRadius.Metrics.formRowLeadingPadding)
        .padding(.trailing, HfRadius.Metrics.formRowTrailingPadding)
        .frame(minHeight: HfRadius.Metrics.formRowHeight)
    }
}

// MARK: - GroupedFormDivider

/// The inset hairline between grouped form rows, aligned with the rows' label column.
public struct GroupedFormDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: HfRadius.Metrics.hairlineStroke)
            .padding(.leading, HfRadius.Metrics.formRowLeadingPadding)
    }
}

// MARK: - CompactStepper

/// Native minus/value/plus buttons. The caller owns the binding, bounds and positive step.
/// Only valid in-range changes are offered; disabled native buttons retain system semantics.
public struct CompactStepper: View {
    public let title: String
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let step: Int

    public init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
        precondition(step > 0, "CompactStepper requires a positive step")
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    /// A legal adjacent value, or nil at a bound or arithmetic overflow.
    public nonisolated static func adjacentValue(_ value: Int, in range: ClosedRange<Int>, step: Int, increment: Bool) -> Int? {
        guard step > 0 else { return nil }
        let result = increment ? value.addingReportingOverflow(step) : value.subtractingReportingOverflow(step)
        return !result.overflow && range.contains(result.partialValue) ? result.partialValue : nil
    }

    public var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing4) {
            stepButton(increment: false)
            Text(value.formatted())
.font(.hf(.secondary))
.monospacedDigit()
                .frame(minWidth: HfRadius.Metrics.compactValueWidth)
                .foregroundStyle(Color.primaryText)
                .accessibilityLabel("\(title), \(value)")
            stepButton(increment: true)
        }
    }

    private func stepButton(increment: Bool) -> some View {
        let next = Self.adjacentValue(value, in: range, step: step, increment: increment)
        return Button {
            if let next { value = next }
        } label: {
            Image(systemName: increment ? "plus" : "minus")
                .font(.hf(.secondary))
                .frame(width: HfRadius.Metrics.compactControlHeight, height: HfRadius.Metrics.compactControlHeight)
        }
        .buttonStyle(.bordered)
        .disabled(next == nil)
        .accessibilityLabel("\(increment ? "Increase" : "Decrease") \(title)")
    }
}

// MARK: - GroupedFormPopup

/// A native menu presenting the selected value and an up/down chevron. Selection and options
/// belong to the caller; this wrapper adds no persistence or feature actions.
public struct GroupedFormPopup<Value: Hashable>: View {
    public let title: String
    public let options: [(value: Value, title: String)]
    @Binding private var selection: Value

    public init(_ title: String, options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.title = title
        self.options = options
        _selection = selection
    }

    public var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection = option.value } label: {
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: HfRadius.Metrics.spacing6) {
                Text(options.first { $0.value == selection }?.title ?? title)
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(.hf(.secondary))
            .foregroundStyle(Color.primaryText)
            .monospacedDigit()
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.value == selection }?.title ?? title)
    }
}

#if DEBUG
/// Dummy values for the preview only — a native stepper and popup shown as-is, no feature form
/// adopts these primitives in Phase 0.
private struct GroupedFormPreview: View {
    @State private var attempts = 3
    @State private var model = "Default"

    var body: some View {
        GroupedForm {
            GroupedFormRow("Decision attempts") {
                CompactStepper("Decision attempts", value: $attempts, in: 1 ... 10)
            }
            GroupedFormDivider()
            GroupedFormRow("Model") {
                GroupedFormPopup("Model", options: ["Default", "Fast", "Balanced"].map { ($0, $0) }, selection: $model)
            }
            GroupedFormDivider()
            GroupedFormRow("Agent") {
                Text("Claude").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            }
        }
        .padding()
        .frame(width: HfRadius.Metrics.formPreviewWidth)
        .background(Color.windowBG)
    }
}

#Preview("GroupedForm - light") { GroupedFormPreview().preferredColorScheme(.light) }
#Preview("GroupedForm - dark") { GroupedFormPreview().preferredColorScheme(.dark) }
#Preview("Form primitives - Reduce Motion") { GroupedFormPreview().environment(\.hfReduceMotionOverride, true) }
#endif
