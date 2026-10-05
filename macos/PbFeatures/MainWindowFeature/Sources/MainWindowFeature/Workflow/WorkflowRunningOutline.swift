import PbUI
import SwiftUI

// MARK: - WorkflowNodeOutline

/// Selection and execution are independent presentation states; reservation is not execution.
struct WorkflowNodeOutline {
    let status: String
    let isSelected: Bool
    var isExecuting: Bool { status == "running" }
    var isEmphasized: Bool { isSelected || isExecuting || status == "reserved" }
}

// MARK: - WorkflowRunningOutline

struct WorkflowRunningOutline: View {
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
            RoundedRectangle(cornerRadius: PbRadius.card + (isSelected ? 3 : 0))
                .inset(by: isSelected ? -3 : 0)
                .strokeBorder(AngularGradient(
                    colors: [.accentLink.opacity(0.15), .accentLink.opacity(0.15), .accentLink, .accentLink.opacity(0.15)],
                    center: .center, startAngle: .degrees(phase * 360), endAngle: .degrees(phase * 360 + 360)
                ), lineWidth: 2)
        }
    }
}

#if DEBUG
#Preview {
    WorkflowRunningOutline(isSelected: true).frame(width: 200, height: 90).padding()
}
#endif
