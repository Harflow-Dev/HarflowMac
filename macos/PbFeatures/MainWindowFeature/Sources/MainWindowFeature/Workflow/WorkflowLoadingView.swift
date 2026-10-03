import PbUI
import SwiftUI

// MARK: - WorkflowLoadingView

struct WorkflowLoadingView: View {
    let isRun: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let scale = min(1, max(0.2, (geometry.size.width - 40) / 508))
                    HStack(spacing: 0) {
                        node(compact: true)
                        connector
                        node(compact: false)
                        connector
                        node(compact: false)
                        connector
                        node(compact: true)
                    }
                    .frame(width: 508, height: 86)
                    .scaleEffect(scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }.clipped()
                VStack(alignment: .leading, spacing: 16) {
                    SkeletonBlock(width: 110, height: 16)
                    SkeletonRows(count: isRun ? 3 : 5)
                    if !isRun { SkeletonBlock(height: 100) }
                    Spacer()
                }
.padding(16)
.frame(width: 240)
.background(Color.cardFill)
            }.frame(minHeight: 220, maxHeight: isRun ? 300 : .infinity)
            if isRun {
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    ForEach(0 ..< 2) { _ in
                        VStack(alignment: .leading, spacing: 18) {
                            SkeletonBlock(width: 120, height: 16)
                            SkeletonBlock(height: 60)
                            SkeletonRows(count: 3)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(24)
                Spacer()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRun ? "Loading workflow run" : "Loading workflow canvas")
    }

    private var connector: some View {
        connectorShapes(.skeletonFill).shimmering().mask(connectorShapes(.white))
    }

    private func connectorShapes(_ color: Color) -> some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 43))
                path.addLine(to: CGPoint(x: 37.5, y: 43))
                path.move(to: CGPoint(x: 31.5, y: 37))
                path.addLine(to: CGPoint(x: 37.5, y: 43))
                path.addLine(to: CGPoint(x: 31.5, y: 49))
            }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            Circle().fill(color).frame(width: 5, height: 5).position(x: 0, y: 43)
            Circle().fill(color).frame(width: 5, height: 5).position(x: 40, y: 43)
        }
.frame(width: 40, height: 86)
    }

    private func node(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(width: compact ? 24 : 75, height: 12)
            if !compact { SkeletonBlock(width: 45, height: 8) }
        }
        .padding(14)
        .frame(width: compact ? 64 : 130, height: compact ? 64 : 86)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardBorder))
    }
}

#if DEBUG
#Preview("Workflow canvas loading") { WorkflowLoadingView(isRun: false).frame(width: 1000, height: 600) }
#Preview("Workflow run loading") { WorkflowLoadingView(isRun: true).frame(width: 1000, height: 600) }
#endif
