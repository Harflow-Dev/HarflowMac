import Foundation
import MonitorCore

// MARK: - ParallelActivityViewport

/// Inspector selection and standalone horizontal geometry share the same residency pipeline.
enum ParallelActivityViewport {
    static func conversationIDs(_ conversations: [Conversation], inspector: Bool, selectedID: String?,
                                offset: CGFloat, width: CGFloat) -> Set<String> {
        if inspector {
            guard width.isFinite, width > 0, let selectedID else { return [] }
            return [selectedID]
        }
        let stride = ParallelLayout.columnWidth(memberCount: conversations.count, availableWidth: width)
            + ParallelLayout.dividerWidth
        let shown = ParallelResidency.visibleIndices(count: conversations.count, offset: offset, width: width, stride: stride)
        return Set(shown.map { conversations[$0].id })
    }
}
