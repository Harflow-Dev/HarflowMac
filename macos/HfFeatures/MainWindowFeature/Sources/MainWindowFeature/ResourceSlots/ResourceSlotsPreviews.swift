#if DEBUG
import HfUI
import SwiftUI

private let syntheticBlockers = ResourceSlotsBlockers(
    rows: [.init(id: "synthetic-blocker", text: "Synthetic task · holder · Cleanup pending · since 10:30")],
    note: "Additional blockers may be unavailable."
)
private let syntheticOwner = ResourceSlotsOwner(
    id: "synthetic-row", title: "Synthetic task with a long title", ownerID: "synthetic-task-id",
    status: "Waiting", since: "Since 10:31", detail: nil, position: "1",
    action: .init(label: "Open task", ownerID: "synthetic-task-id"), blockers: syntheticBlockers
)
private let syntheticReady = ResourceSlotsPresentation(
    state: .ready(summary: "0 held · 1 waiting", groups: [
        .init(id: "synthetic-resource", title: "synthetic-resource", capacitySummary: "0 of 1 in use",
              holderHeading: "Current holder", holders: [], emptyHolderMessage: "No synthetic holders.",
              waiterHeading: "Waiting · in order", waiters: [syntheticOwner])
    ]), qualifiers: []
)
@MainActor
private func resourcePreview(_ presentation: ResourceSlotsPresentation) -> some View {
    ResourceSlotsContent(presentation: presentation, readingState: ResourceSlotsReadingState(), expandedResourceIDs: ["synthetic-resource"],
                         expandedBlockerIDs: ["synthetic-row"], onToggleResource: { _ in },
                         onToggleBlockers: { _ in }, onOpenOwner: { _ in })
        .frame(width: 850, height: 700)
}

#Preview("Synthetic populated light") { resourcePreview(syntheticReady).preferredColorScheme(.light) }
#Preview("Synthetic populated dark") { resourcePreview(syntheticReady).preferredColorScheme(.dark) }
#Preview("Synthetic loading static") {
    resourcePreview(.init(state: .loading, qualifiers: [])).environment(\.hfReduceMotionOverride, true)
}

#Preview("Synthetic unavailable") {
    resourcePreview(.init(state: .unavailable(title: "Resource slots unavailable", message: "Synthetic diagnostic"), qualifiers: []))
}

#Preview("Synthetic cleanup") {
    TaskResourceContextView(context: .init(title: "Resource slot context", message: "Cleanup pending; capacity remains held.",
                                           detail: "Synthetic resource · since 10:30", blockers: syntheticBlockers),
                            blockersExpanded: true, onToggleBlockers: {}, onOpenResourceSlots: {})
        .padding()
.frame(width: 600)
}
#endif
