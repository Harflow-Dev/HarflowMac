import AppKit
import HfUI
import SwiftUI

// MARK: - WorkflowScrollRowMetrics

/// Layout metrics shared by `WorkflowScrollRow` and the layouts that size around it.
enum WorkflowScrollRowMetrics {
    /// Thickness of the small overlay scroller, reserved below the row's content.
    static var gutter: CGFloat { NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay) }
}

// MARK: - WorkflowScrollRow

/// The workflow editor's horizontal scroll row, shared by the standalone strip and the step tray.
/// It uses the monitor's overlay scroll chrome and always reserves a fixed bottom gutter, as tall
/// as the small overlay scroller, so the scroller sits below the content instead of covering it
/// and the row's height never changes when the scroller appears. The row's height is measured
/// from its content and pinned, so scroller style changes cannot resize it. While the pointer is
/// over the row, `ScrollHoverReveal` keeps the scroller revealed (and for a moment after it leaves),
/// so it can be dragged without a horizontal scroll device. The trailing fade covers the content
/// only, not the gutter, and its width matches the trailing padding, so the last item is fully
/// opaque once scrolled to the end.
struct WorkflowScrollRow<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var measuredHeight: CGFloat?

    var body: some View {
        ScrollView(.horizontal) {
            content
                .padding(.trailing, HfRadius.Metrics.spacing16)
                .padding(.bottom, WorkflowScrollRowMetrics.gutter)
                .background(ScrollChrome())
                .background(ScrollHoverReveal())
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { measuredHeight = $0 })
        }
        .frame(height: measuredHeight)
        .fixedSize(horizontal: false, vertical: measuredHeight == nil)
        .mask {
            VStack(spacing: HfRadius.Metrics.zero) {
                HStack(spacing: HfRadius.Metrics.zero) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: HfRadius.Metrics.spacing16)
                }
                Rectangle().frame(height: WorkflowScrollRowMetrics.gutter)
            }
        }
    }
}

#if DEBUG
#Preview("Workflow scroll row") {
    WorkflowScrollRow {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            ForEach(0 ..< 12, id: \.self) { Text("Item \($0)").padding(HfRadius.Metrics.spacing8) }
        }
    }
    .frame(width: 320)
}
#endif
