import Foundation
import HfRepository

// MARK: - NeedsYouQuestionAssembly

/// Pure screen-session reconciliation, called only in the existing detached presentation build.
enum NeedsYouQuestionAssembly {
    struct Result: Sendable {
        let cards: [NeedsYouQuestion]
        let suppressed: [NeedsYouQuestionIdentity]
    }

    static func reconcile(_ previous: [NeedsYouQuestion], suppressed: [NeedsYouQuestionIdentity], snapshot: NeedsYouSnapshot) -> Result {
        var cards = previous
        let live = snapshot.items.filter { $0.kind == .question && !$0.rootRunID.isEmpty }
        let withdrawn = snapshot.withdrawn.filter { $0.kind == .question && !$0.rootRunID.isEmpty }
        let observed = live + withdrawn
        let observedByID = Dictionary(grouping: observed, by: \.id)
        let withdrawnByID = Dictionary(grouping: withdrawn, by: \.id)
        var suppressed = suppressed.filter { identity in observedByID[identity.id]?.contains(where: identity.matches) == true }
        let suppressedByID = Dictionary(grouping: suppressed, by: \.id)
        var indicesByID = Dictionary(grouping: cards.indices, by: { cards[$0].item.id })
        for index in cards.indices where !cards[index].isPending {
            if !contains(cards[index].item, in: observedByID) { cards[index].absentSeen = true }
        }
        for item in observed where suppressedByID[item.id]?.contains(where: { $0.matches(item) }) != true {
            let candidates = indicesByID[item.id] ?? []
            let isWithdrawn = contains(item, in: withdrawnByID)
            if let index = candidates.first(where: { cards[$0].item.isSameRequest(as: item) && !cards[$0].terminal && !cards[$0].absentSeen }) {
                update(&cards[index], item: item, withdrawn: isWithdrawn)
            } else if !candidates.contains(where: { cards[$0].item.isSameRequest(as: item) && !cards[$0].absentSeen }) {
                var detail = NeedsYouPresentationMapper.detail(item)
                if isWithdrawn { detail.phase = .withdrawn }
                indicesByID[item.id, default: []].append(cards.count)
                cards.append(NeedsYouQuestion(id: UUID(), item: item, detail: detail))
            }
        }
        for index in cards.indices where cards[index].isPending {
            if !contains(cards[index].item, in: observedByID) { expire(&cards[index]) }
        }
        // Pending and unreadable-source drafts remain unbounded; all nonpending receipts share the existing bound.
        let receipts = cards.filter { !$0.isPending }.map(\.id)
        let excess = Set(receipts.prefix(max(0, receipts.count - NeedsYouVM.settledLimit)))
        suppressed += cards.filter { excess.contains($0.id) && !$0.absentSeen && contains($0.item, in: observedByID) }.map { NeedsYouQuestionIdentity($0.item) }
        cards.removeAll { excess.contains($0.id) }
        return Result(cards: cards, suppressed: suppressed)
    }

    private static func contains(_ item: NeedsYouItem, in grouped: [String: [NeedsYouItem]]) -> Bool {
        grouped[item.id]?.contains(where: { $0.isSameRequest(as: item) }) == true
    }

    private static func update(_ card: inout NeedsYouQuestion, item: NeedsYouItem, withdrawn: Bool) {
        guard card.isPending else { return }
        // Typing changes only the draft. Reuse the already formatted prose/provenance for an unchanged request.
        if card.item != item {
            var detail = NeedsYouPresentationMapper.detail(item)
            detail.error = card.detail.error
            card.detail = detail
            card.item = item
        }
        card.detail.phase = card.submitting ? .submitting : withdrawn ? .withdrawn : .answerable
    }

    private static func expire(_ card: inout NeedsYouQuestion) {
        card.absentSeen = true
        if card.submitting {
            card.detail.phase = .submitting
            return
        }
        card.isPending = false
        card.terminal = true
        card.detail.phase = .expired
        card.detail.savedDraft = card.draft.isEmpty ? nil : card.draft
    }
}
