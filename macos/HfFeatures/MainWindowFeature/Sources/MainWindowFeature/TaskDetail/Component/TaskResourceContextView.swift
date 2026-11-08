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
    /// The standalone mount draws the card with the M05 resource card metrics; its strings are unchanged.
    var usesM05Metrics = false

    private typealias Metrics = TaskScreenStyle.ResourceCard

    var body: some View {
        VStack(alignment: .leading, spacing: usesM05Metrics ? Metrics.gap : 8) {
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
            openSlotsButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(usesM05Metrics ? Metrics.padding : 16)
        .background(usesM05Metrics ? Metrics.fill.color : Color.cardFill,
                    in: RoundedRectangle(cornerRadius: usesM05Metrics ? Metrics.cornerRadius : HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: usesM05Metrics ? Metrics.cornerRadius : HfRadius.card)
            .stroke(usesM05Metrics ? Metrics.borderColor.color : Color.cardBorder, lineWidth: usesM05Metrics ? Metrics.borderWidth : 1))
    }

    /// The standalone card tints the link; Group's button gets no tint modifier at all.
    @ViewBuilder private var openSlotsButton: some View {
        let button = Button("Open resource slots", action: onOpenResourceSlots).buttonStyle(.link)
        if usesM05Metrics { button.tint(Metrics.linkColor.color) } else { button }
    }
}
