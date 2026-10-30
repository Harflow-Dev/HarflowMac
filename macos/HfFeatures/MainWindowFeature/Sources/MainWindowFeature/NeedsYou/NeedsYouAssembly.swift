import Foundation
import HfRepository

// MARK: - NeedsYouAssemblyInput

/// Immutable inputs for one off-main presentation build.
struct NeedsYouAssemblyInput: Sendable {
    let snapshot: NeedsYouSnapshot
    let selectedID: String?
    let overrides: [String: NeedsYouItem]
    let reviewNotes: [String: String]
    let settled: NeedsYouDetail?
    let lastDetails: [String: NeedsYouDetail]
    let leavingRows: [String: NeedsYouRow]
    let submittingID: String?
    let sendError: String?
    let notice: String?
}

struct NeedsYouAssemblyResult: Sendable {
    let presentation: NeedsYouPresentation
    let detail: NeedsYouDetail?
}

// MARK: - NeedsYouAssembly

enum NeedsYouAssembly {
    nonisolated static func assemble(_ input: NeedsYouAssemblyInput) -> NeedsYouAssemblyResult {
        let leavingIDs = Set(input.leavingRows.keys)
        var presentation = NeedsYouPresentationMapper.presentation(input.snapshot, leaving: leavingIDs)
        let present = Set(presentation.rows.map(\.id))
        let extra = input.leavingRows.values.filter { !present.contains($0.id) }
        if !extra.isEmpty {
            presentation.rows = (presentation.rows + extra).sorted {
                ($0.waitingSince ?? .distantFuture, $0.id) < ($1.waitingSince ?? .distantFuture, $1.id)
            }
        }
        presentation.notice = input.notice
        guard let id = input.selectedID else { return NeedsYouAssemblyResult(presentation: presentation, detail: nil) }
        let detail = detail(id: id, input: input, loading: presentation.isLoading)
        presentation.detail = detail
        presentation.detailIsLoading = detail == nil
        presentation.showsDetail = true
        return NeedsYouAssemblyResult(presentation: presentation, detail: detail)
    }

    private nonisolated static func detail(id: String, input: NeedsYouAssemblyInput, loading: Bool) -> NeedsYouDetail? {
        if let settled = input.settled, settled.id == id { return settled }
        if let item = input.overrides[id] ?? input.snapshot.items.first(where: { $0.id == id }) {
            var detail = NeedsYouPresentationMapper.detail(item)
            if input.submittingID == id { detail.phase = .submitting }
            detail.error = input.sendError
            detail.reviewNote = input.reviewNotes[id]
            return detail
        }
        if loading { return nil }
        // Resolved without a local answer: expired, or another responder answered it. Nothing was sent.
        if var last = input.lastDetails[id] {
            last.phase = .expired
            last.error = nil
            last.reviewNote = nil
            return last
        }
        return NeedsYouDetail(
            id: id, kind: .question, kindLabel: "Request", title: "Request", pathTitles: [], text: "", questionItems: [],
            offeredAnswers: nil, resumeHint: nil, approval: nil, provenance: [], ownershipNote: "", canAddAttempts: false,
            phase: .expired, error: nil, reviewNote: nil
        )
    }
}
