import Foundation
import HfRepository

// MARK: - NeedsYouQuestion

/// A screen-session mount of an exact workflow question. The token changes after absence or replacement.
struct NeedsYouQuestion: Equatable, Sendable, Identifiable {
    let id: UUID
    var item: NeedsYouItem
    var detail: NeedsYouDetail
    var draft = ""
    var isPending = true
    var submitting = false
    var terminal = false
    var absentSeen = false
}

// MARK: - NeedsYouQuestionIdentity

/// Lightweight workflow identity only; evicted receipts never keep question prose or a local draft.
struct NeedsYouQuestionIdentity: Equatable, Sendable {
    let id: String
    let decisionID: String?
    let rootRunID: String
    let sourceRunID: String
    let taskID: String?
    let checkpointID: String?
    let context: WorkflowResponseContext?

    init(_ item: NeedsYouItem) {
        self.id = item.id
        self.decisionID = item.decisionID
        self.rootRunID = item.rootRunID
        self.sourceRunID = item.sourceRunID
        self.taskID = item.taskID
        self.checkpointID = item.attentionCheckpointID
        self.context = item.workflowContext
    }

    func matches(_ item: NeedsYouItem) -> Bool { item.kind == .question && self == Self(item) }
}

// MARK: - Inline questions

extension NeedsYouVM {
    func reconcileQuestionScope() {
        let context = snapshot.workflowContext
        if questionContext != context {
            clearQuestions()
            questionContext = context
        }
    }

    func clearQuestions() {
        questions = []
        questionSuppressed = []
        clearInlineQuestionPresentation()
        questionLifecycle += 1
    }

    /// Shares an observed successful detail receipt with its original inline request, never a replacement.
    func mirrorInlineReceipt(_ receipt: NeedsYouDetail, for item: NeedsYouItem) -> NeedsYouDetail {
        guard case .settled = receipt.phase, didSubscribe, questionContext == useCase.snapshot.workflowContext,
              let index = questions.firstIndex(where: { $0.item.isSameRequest(as: item) }) else { return receipt }
        var receipt = receipt
        if receipt.savedDraft == nil, !questions[index].draft.isEmpty { receipt.savedDraft = questions[index].draft }
        questions[index].detail = receipt
        questions[index].isPending = false
        questions[index].terminal = true
        questions[index].submitting = false
        return receipt
    }

    private func questionIndex(_ rendered: NeedsYouQuestion, actionable: Bool) -> Int? {
        guard didSubscribe, useCase.snapshot.workflowContext == questionContext, let index = questions.firstIndex(where: { $0.id == rendered.id }),
              questions[index].item == rendered.item else { return nil }
        if actionable {
            guard questions[index].isPending, !questions[index].submitting,
                  questions[index].detail.phase == .answerable,
                  useCase.snapshot.items.contains(rendered.item),
                  !useCase.snapshot.withdrawn.contains(where: { $0.isSameRequest(as: rendered.item) }) else { return nil }
        }
        return index
    }

    func questionDraft(for rendered: NeedsYouQuestion) -> String {
        guard let index = questionIndex(rendered, actionable: false) else { return rendered.draft }
        return questions[index].draft
    }

    func setQuestionDraft(_ text: String, for rendered: NeedsYouQuestion) {
        guard let index = questionIndex(rendered, actionable: true), questions[index].draft != text else { return }
        questions[index].draft = text
        rebuild()
    }

    func retryQuestion(_ rendered: NeedsYouQuestion) {
        guard let index = questionIndex(rendered, actionable: false), questions[index].detail.phase == .withdrawn else { return }
        useCase.refresh()
    }

    func openQuestionRun(_ rendered: NeedsYouQuestion) {
        guard questionIndex(rendered, actionable: false) != nil, !rendered.item.rootRunID.isEmpty else { return }
        routing.openNeedsYouRun(rendered.item.rootRunID)
    }

    func submitQuestion(_ rendered: NeedsYouQuestion, offered: String?) {
        guard let index = questionIndex(rendered, actionable: true) else { return }
        let text: String
        if let offered {
            guard rendered.item.offeredAnswers?.contains(offered) == true else { return }
            text = offered
        } else {
            guard rendered.item.offeredAnswers == nil else { return }
            text = questions[index].draft
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        questions[index].submitting = true
        questions[index].detail.error = nil
        let started = questionLifecycle
        rebuild()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await useCase.answer(rendered.item, text: text, additionalAttempts: nil)
            finishQuestion(outcome, rendered: rendered, text: text, lifecycle: started)
        }
    }

    private func finishQuestion(_ outcome: NeedsYouAnswerOutcome, rendered: NeedsYouQuestion, text: String, lifecycle: Int) {
        guard didSubscribe, questionLifecycle == lifecycle, useCase.snapshot.workflowContext == questionContext,
              let index = questions.firstIndex(where: { $0.id == rendered.id }),
              questions[index].item.isSameRequest(as: rendered.item) else { return }
        questions[index].submitting = false
        let current = useCase.snapshot
        let live = current.items.first { $0.id == rendered.item.id } ?? current.withdrawn.first { $0.id == rendered.item.id }
        let stillObserved = live?.isSameRequest(as: rendered.item) == true
        switch outcome {
        case .accepted:
            questions[index].detail.phase = .settled(decision: "Answered", answer: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     note: NeedsYouPresentationMapper.settledNote(rendered.item))
            questions[index].draft = ""
            questions[index].isPending = false
            questions[index].terminal = true
        case .alreadyAnswered(let answer, let owner, let timestamp, let truncated):
            let label = owner == .caller ? "Already answered by the caller" : "Answered in Harflow"
            let time = Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
            questions[index].detail.phase = .settled(decision: label, answer: answer, note: (truncated ? "Answer excerpt · " : "") + time)
            questions[index].detail.savedDraft = questions[index].draft.isEmpty ? nil : questions[index].draft
            questions[index].isPending = false
            questions[index].terminal = true
            useCase.refresh()
        case .callerReturned(let message):
            questions[index].detail.phase = .readOnly(lines: [message], refresh: false)
            questions[index].detail.savedDraft = questions[index].draft.isEmpty ? nil : questions[index].draft
            questions[index].isPending = false
            questions[index].terminal = true
            useCase.refresh()
        case .failed(let message), .stale(let message):
            if stillObserved, !questions[index].absentSeen {
                questions[index].detail.error = message
            } else {
                questions[index].detail.phase = .readOnly(lines: [message], refresh: false)
                questions[index].detail.savedDraft = questions[index].draft.isEmpty ? nil : questions[index].draft
                questions[index].isPending = false
                questions[index].terminal = true
            }
        case .changed:
            questions[index].detail.phase = .readOnly(lines: [NeedsYouAnswerOutcome.changedMessage], refresh: false)
            questions[index].detail.savedDraft = questions[index].draft.isEmpty ? nil : questions[index].draft
            questions[index].isPending = false
            questions[index].terminal = true
            useCase.refresh()
        case .approvalOutcome:
            questions[index].detail.phase = .readOnly(lines: ["This request cannot be answered here."], refresh: false)
            questions[index].isPending = false
            questions[index].terminal = true
        }
        let replacementMounted = questions.contains {
            $0.id != rendered.id && !$0.absentSeen && $0.item.isSameRequest(as: rendered.item)
        }
        if case .settled = questions[index].detail.phase, !replacementMounted, live == nil || stillObserved {
            recordSettled(questions[index].detail, for: rendered.item)
        }
        rebuild()
    }
}
