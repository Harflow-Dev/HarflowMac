import Foundation
import HfRepository

// MARK: - Answering

extension NeedsYouVM {
    private var currentItem: NeedsYouItem? {
        guard let id = selectedID, submittingID == nil, settled == nil else { return nil }
        return overrides[id] ?? snapshot.items.first { $0.id == id }
    }

    func didSubmitAnswer() {
        guard let item = currentItem, item.kind != .approval else { return }
        send(item, text: answerText)
    }

    func didChooseOffered(_ answer: String) {
        guard let item = currentItem, item.kind == .question, item.offeredAnswers?.contains(answer) == true else { return }
        send(item, text: answer)
    }

    func didDecide(approve: Bool) {
        guard let item = currentItem, item.kind == .approval else { return }
        submittingID = item.id
        sendError = nil
        rebuild()
        let decision = approve ? "approve" : "reject"
        Task { [weak self] in
            guard let self else { return }
            let outcome = await useCase.respond(item, decision: decision)
            finish(outcome, item: item, answer: "", rejected: !approve)
        }
    }

    private func send(_ item: NeedsYouItem, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submittingID = item.id
        sendError = nil
        rebuild()
        let attempts = item.kind == .recovery && item.canAddAttempts ? max(0, additionalAttempts) : nil
        Task { [weak self] in
            guard let self else { return }
            let outcome = await useCase.answer(item, text: text, additionalAttempts: attempts)
            finish(outcome, item: item, answer: trimmed, rejected: false)
        }
    }

    private func finish(_ outcome: NeedsYouAnswerOutcome, item: NeedsYouItem, answer: String, rejected: Bool) {
        submittingID = nil
        switch outcome {
        case .accepted:
            var detail = NeedsYouPresentationMapper.detail(item)
            detail.phase = .settled(decision: NeedsYouPresentationMapper.settledDecision(item, rejected: rejected), answer: answer,
                                    note: NeedsYouPresentationMapper.settledNote(item))
            settled = detail
            answerText = ""
            sendError = nil
            fadeOut(item)
        case .callerReturned(let message):
            notice = message
            answerText = ""
            sendError = nil
            show(itemID: nil)
            routing.showNeedsYou(itemID: nil)
            useCase.refresh()
            return
        case .stale(let message), .failed(let message):
            sendError = message
        case .changed(let refreshed):
            if let refreshed { overrides[item.id] = refreshed }
            reviewNotes[item.id] = NeedsYouAnswerOutcome.changedMessage
            sendError = nil
            useCase.refresh()
        }
        rebuild()
    }

    /// Keeps the answered row for the 180 ms fade; under Reduce Motion it leaves at once.
    private func fadeOut(_ item: NeedsYouItem) {
        guard !reduceMotion else { return }
        var row = NeedsYouPresentationMapper.row(item)
        row.isLeaving = true
        leavingRows[item.id] = row
        fadeTasks[item.id]?.cancel()
        fadeTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.fadeMilliseconds))
            guard let self, !Task.isCancelled else { return }
            leavingRows[item.id] = nil
            fadeTasks[item.id] = nil
            rebuild()
        }
    }
}
