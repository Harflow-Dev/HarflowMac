import Combine
import Foundation
import HfCommon
import HfRepository
import HfUtilities
import Mockable

// MARK: - NeedsYouUseCase

/// The screen's data needs over `NeedsYouRepository`.
@Mockable
@MainActor
protocol NeedsYouUseCase: Sendable {
    var snapshot: NeedsYouSnapshot { get }
    func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never>
    /// Requests an immediate engine pass.
    func refresh()
    func answer(_ item: NeedsYouItem, text: String, additionalAttempts: Int?) async -> NeedsYouAnswerOutcome
    func canReviewApprovalAgain(_ item: NeedsYouItem) async -> Bool
    func respond(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome
}

extension NeedsYouUseCase {
    func canReviewApprovalAgain(_: NeedsYouItem) async -> Bool { false }
}

// MARK: - NeedsYouRouting

/// Navigation Needs you performs; the coordinator owns the selection.
@Mockable
@MainActor
protocol NeedsYouRouting: Sendable {
    /// Opens Needs you, showing one request's detail or the list when `itemID` is nil.
    func showNeedsYou(itemID: String?)
    func openNeedsYouRun(_ runID: String)
}

extension NeedsYouRouting {
    func openNeedsYouRun(_: String) {}
}

// MARK: - NeedsYouVM

@Observable
@MainActor
final class NeedsYouVM: NeedsYouViewModel {
    static let fadeMilliseconds = 180

    private(set) var presentation = NeedsYouPresentation()
    var answerText = ""
    var additionalAttempts = 1

    @ObservationIgnored let useCase: any NeedsYouUseCase
    @ObservationIgnored let routing: any NeedsYouRouting
    @ObservationIgnored var cancellables = Set<AnyCancellable>()
    @ObservationIgnored var didSubscribe = false
    @ObservationIgnored var snapshot = NeedsYouSnapshot()
    var questions: [NeedsYouQuestion] = []
    @ObservationIgnored var questionSuppressed: [NeedsYouQuestionIdentity] = []
    @ObservationIgnored var questionContext: WorkflowResponseContext?
    @ObservationIgnored var questionLifecycle = 0
    @ObservationIgnored var selectedID: String?
    @ObservationIgnored var overrides: [String: NeedsYouItem] = [:]
    @ObservationIgnored var reviewNotes: [String: String] = [:]
    @ObservationIgnored var settled: [String: NeedsYouDetail] = [:]
    /// What each settled card was settled for, so it can never shadow a newer request that reuses the id.
    @ObservationIgnored var settledMeta: [String: SettledMeta] = [:]
    @ObservationIgnored var settledOrder: [String] = []
    /// Advanced when the screen disappears, so a completion started before cannot touch what is shown after.
    @ObservationIgnored var lifecycle = 0
    @ObservationIgnored var rebuildCompletions = 0
    /// The exact item behind the rendered detail. Answers are sent for it, never for a fresh snapshot lookup.
    @ObservationIgnored var displayedItem: NeedsYouItem?
    @ObservationIgnored var lastDetails: [String: NeedsYouDetail] = [:]
    @ObservationIgnored var leavingRows: [String: NeedsYouRow] = [:]
    @ObservationIgnored var submittingIDs: Set<String> = []
    @ObservationIgnored var submittingItems: [String: NeedsYouItem] = [:]
    @ObservationIgnored var sendError: String?
    @ObservationIgnored var notice: String?
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var rebuildTask: Task<Void, Never>?
    @ObservationIgnored var fadeTasks: [String: Task<Void, Never>] = [:]

    init(useCase: any NeedsYouUseCase, routing: any NeedsYouRouting) {
        self.useCase = useCase
        self.routing = routing
    }

    // MARK: - Lifecycle

    func didAppear() {
        guard !didSubscribe else { return }
        didSubscribe = true
        snapshot = useCase.snapshot
        useCase.snapshotPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self else { return }
                snapshot = value
                rebuild()
            }
            .store(in: &cancellables)
        useCase.refresh()
        rebuild()
    }

    func didDisappear() {
        lifecycle += 1
        clearQuestions()
        for task in fadeTasks.values { task.cancel() }
        fadeTasks = [:]
        leavingRows = [:]
        cancellables.removeAll()
        rebuildTask?.cancel()
        rebuildTask = nil
        generation = UUID()
        didSubscribe = false
    }

    func didChangeReduceMotion(_ value: Bool) { reduceMotion = value }

    /// Clears inline rendering at the lifecycle boundary without exposing the presentation setter.
    func clearInlineQuestionPresentation() {
        if !presentation.questions.isEmpty { presentation.questions = [] }
    }

    // MARK: - Navigation

    func show(itemID: String?) {
        guard selectedID != itemID else { return }
        selectedID = itemID
        answerText = ""
        additionalAttempts = 1
        sendError = nil
        if itemID != nil { notice = nil }
        reviewNotes = [:]
        displayedItem = nil
        rebuild()
    }

    func didSelect(_ itemID: String) {
        show(itemID: itemID)
        routing.showNeedsYou(itemID: itemID)
    }

    func didTapBack() {
        show(itemID: nil)
        routing.showNeedsYou(itemID: nil)
    }

    func didTapRetry() {
        useCase.refresh()
        guard let id = selectedID, let item = settledMeta[id]?.item, item.kind == .approval else { return }
        let started = lifecycle
        Task { [weak self] in
            guard let self, await useCase.canReviewApprovalAgain(item), lifecycle == started,
                  selectedID == id, settledMeta[id]?.item.isSameRequest(as: item) == true else { return }
            snapshot = useCase.snapshot
            guard snapshot.items.first(where: { $0.id == id })?.isSameRequest(as: item) == true else { return }
            dropSettled(id)
            rebuild()
        }
    }

    func didDismissNotice() {
        guard notice != nil else { return }
        notice = nil
        rebuild()
    }

    // MARK: - Rebuild

    /// Maps the latest inputs to presentation off the main actor and applies only a changed result.
    func rebuild() {
        reconcileQuestionScope()
        reconcileSettled()
        for (id, submitted) in submittingItems {
            if let live = snapshot.items.first(where: { $0.id == id }), !live.isSameRequest(as: submitted) {
                submittingIDs.remove(id)
                submittingItems[id] = nil
            }
        }
        for (id, override) in overrides {
            if let live = snapshot.items.first(where: { $0.id == id }), !live.isSameRequest(as: override) {
                overrides[id] = nil
                reviewNotes[id] = nil
            }
        }
        // Resolution and withdrawal are authoritative over a local review override.
        for id in overrides.keys where !snapshot.items.contains(where: { $0.id == id }) {
            overrides[id] = nil
            reviewNotes[id] = nil
        }
        rebuildTask?.cancel()
        let token = UUID()
        generation = token
        let input = NeedsYouAssemblyInput(
            snapshot: snapshot, selectedID: selectedID, overrides: overrides, reviewNotes: reviewNotes, settled: settled,
            lastDetails: lastDetails, leavingRows: leavingRows, submittingIDs: submittingIDs, sendError: sendError, notice: notice,
            savedDraft: answerText, questions: questions, questionSuppressed: questionSuppressed
        )
        rebuildTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { NeedsYouAssembly.assemble(input) }.value
            guard let self, !Task.isCancelled, generation == token else { return }
            apply(result)
        }
    }

    private func apply(_ result: NeedsYouAssemblyResult) {
        questionSuppressed = result.questionSuppressed
        if questions != result.presentation.questions { questions = result.presentation.questions }
        if let detail = result.detail, detail.phase == .answerable || detail.phase == .submitting {
            if lastDetails[detail.id]?.id != detail.id || lastDetails[detail.id]?.text != detail.text { lastDetails[detail.id] = detail }
        }
        displayedItem = result.item
        for (id, item) in overrides {
            guard let current = snapshot.items.first(where: { $0.id == id }) else { continue }
            let sameApproval = item.approval.flatMap { shown in current.approval.map { $0.isSameCurrent(as: shown) } } ?? false
            if sameApproval || current == item { overrides[id] = nil }
        }
        if presentation != result.presentation { presentation = result.presentation }
        rebuildCompletions += 1
    }
}

// MARK: - SettledMeta

/// The request a settled card belongs to. `absentSeen` flips once a snapshot has shown the request gone, after
/// which any request with that id is a new one and replaces the card.
struct SettledMeta {
    let item: NeedsYouItem
    var absentSeen: Bool
}

extension NeedsYouVM {
    nonisolated static let settledLimit = 32

    func recordSettled(_ detail: NeedsYouDetail, for item: NeedsYouItem) {
        let detail = mirrorInlineReceipt(detail, for: item)
        settled[item.id] = detail
        settledMeta[item.id] = SettledMeta(item: item, absentSeen: false)
        settledOrder.removeAll { $0 == item.id }
        settledOrder.append(item.id)
        while settledOrder.count > Self.settledLimit { dropSettled(settledOrder[0]) }
        reconcileSettled()
    }

    private func dropSettled(_ id: String) {
        settled[id] = nil
        settledMeta[id] = nil
        settledOrder.removeAll { $0 == id }
    }

    /// Keeps a settled card only while it describes the request that was answered.
    func reconcileSettled() {
        for (id, meta) in settledMeta {
            let live = snapshot.items.first { $0.id == id } ?? snapshot.withdrawn.first { $0.id == id }
            if let live {
                if meta.absentSeen || !live.isSameRequest(as: meta.item) { dropSettled(id) }
            } else {
                settledMeta[id]?.absentSeen = true
            }
        }
    }
}

extension NeedsYouItem {
    /// Whether two copies are the same request: identity fields only, so a copy whose text, notes or ownership
    /// were refreshed while an answer was in flight is still the request that was answered. `waitingSince` is not
    /// identity: for workflow requests the engine derives it from the run's `updated_at`, which a send itself bumps.
    /// A recovery's id carries its source and the fingerprint of its reason, a question's its decision id.
    func isSameRequest(as other: NeedsYouItem) -> Bool {
        id == other.id && kind == other.kind && decisionID == other.decisionID && rootRunID == other.rootRunID
            && sourceRunID == other.sourceRunID && taskID == other.taskID
            && attentionCheckpointID == other.attentionCheckpointID && workflowContext == other.workflowContext
            && approvalContext == other.approvalContext
            && approval?.id == other.approval?.id && approval?.taskID == other.approval?.taskID
            && approval?.revision == other.approval?.revision && approval?.digest == other.approval?.digest
            && approval?.raw["generation"] == other.approval?.raw["generation"]
            && approval?.raw["interaction_owner"] == other.approval?.raw["interaction_owner"]
            && approval?.raw["action"] == other.approval?.raw["action"] && approval?.raw["scope"] == other.approval?.raw["scope"]
    }
}
