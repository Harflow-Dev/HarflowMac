import Foundation
import HfRepository

// MARK: - Answering

extension NeedsYouVM {
    /// The item the reviewer is looking at, or nil when nothing may be sent. If the live item differs from the
    /// rendered one (a new approval revision or action, another question or decision), nothing is sent: the
    /// refreshed item is shown with the review note instead.
    private var currentItem: NeedsYouItem? {
        guard let id = selectedID, !submittingIDs.contains(id), settled[id] == nil, let shown = displayedItem, shown.id == id,
              presentation.detail?.phase != .withdrawn else { return nil }
        let live = overrides[id] ?? snapshot.items.first { $0.id == id }
        guard let live else { return nil }
        guard live == shown else {
            overrides[id] = live
            reviewNotes[id] = NeedsYouAnswerOutcome.changedMessage
            sendError = nil
            rebuild()
            return nil
        }
        return shown
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
        submittingIDs.insert(item.id)
        sendError = nil
        rebuild()
        let decision = approve ? "approve" : "reject"
        let started = lifecycle
        Task { [weak self] in
            guard let self else { return }
            let outcome = await useCase.respond(item, decision: decision)
            finish(outcome, item: item, answer: "", rejected: !approve, lifecycle: started)
        }
    }

    private func send(_ item: NeedsYouItem, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submittingIDs.insert(item.id)
        sendError = nil
        rebuild()
        let attempts = item.kind == .recovery && item.canAddAttempts ? max(0, additionalAttempts) : nil
        let started = lifecycle
        Task { [weak self] in
            guard let self else { return }
            let outcome = await useCase.answer(item, text: text, additionalAttempts: attempts)
            finish(outcome, item: item, answer: trimmed, rejected: false, lifecycle: started)
        }
    }

    /// Applies a completion. The engine result already updated the repository; what is shown changes only if the
    /// request is still the one selected and the screen has not been torn down since the send started.
    private func finish(_ outcome: NeedsYouAnswerOutcome, item: NeedsYouItem, answer: String, rejected: Bool, lifecycle started: Int) {
        submittingIDs.remove(item.id)
        let current = selectedID == item.id && lifecycle == started
        if case .accepted = outcome {
            // A settled card is kept for the request itself, wherever the reviewer has navigated since.
            var detail = NeedsYouPresentationMapper.detail(item)
            detail.phase = .settled(decision: NeedsYouPresentationMapper.settledDecision(item, rejected: rejected), answer: answer,
                                    note: NeedsYouPresentationMapper.settledNote(item))
            settled[item.id] = detail
            if current {
                answerText = ""
                sendError = nil
            }
            fadeOut(item)
            rebuild()
            return
        }
        guard current else {
            rebuild()
            return
        }
        switch outcome {
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
        case .accepted:
            break
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
