import HfUI
import SwiftUI

struct TaskResourceContext: Equatable, Sendable {
    let title: String
    let message: String
    let detail: String?
    let blockers: ResourceSlotsBlockers?
}

struct TaskResourceContextView: View {
    let context: TaskResourceContext
    let blockersExpanded: Bool
    let onToggleBlockers: () -> Void
    let onOpenResourceSlots: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(context.title).font(.hf(.headline, weight: .semibold))
            Text(context.message).font(.hf(.body)).fixedSize(horizontal: false, vertical: true)
            if let detail = context.detail {
                Text(detail)
.font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let blockers = context.blockers {
                DisclosureGroup(isExpanded: Binding(get: { blockersExpanded }, set: { _ in onToggleBlockers() })) {
                    ScrollView {
                        ResourceSlotsBlockerContent(blockers: blockers)
                    }
                    .frame(maxHeight: 160)
                    .accessibilityLabel("Resource blockers")
                } label: {
                    Text("Blocking details")
                }
            }
            Button("Open resource slots", action: onOpenResourceSlots).buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
    }
}
