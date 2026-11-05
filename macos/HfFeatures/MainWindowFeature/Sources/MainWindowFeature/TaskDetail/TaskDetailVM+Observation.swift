import Combine
import Foundation
import HfRepository

extension TaskDetailVM {
    var orderedHistoryFrames: [EventObservationFrame] {
        conversationMembers.filter { loadedActivityMembers.contains($0.taskID) && leases[$0.taskID] != nil }
            .compactMap { observationFrames[$0.taskID] }
    }

    func observeRequest(_ id: String) {
        guard requestTaskID != id else { return }
        requestTaskID = id
        copyFeedback = nil
        requestSubscriptions.removeAll()
        requestReadState = useCase.requestState(for: id)
        let epoch = timelineEpoch
        requestSubscriptions.append(useCase.requestPublisher(for: id).receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self, timelineEpoch == epoch, requestTaskID == id,
                  useCase.requestState(for: id) == state else { return }
            requestReadState = state
            if state == .notRequested { useCase.readRequest(for: id, maxBytes: 65536) }
        })
        useCase.readRequest(for: id, maxBytes: 65536)
    }

    func observeRecovery(_ id: String) {
        guard recoveryTaskID != id else { return }
        recoveryTaskID = id
        recoverySubscriptions.removeAll()
        recoveredTranscript = useCase.recoveredTranscript(for: id)
        let epoch = timelineEpoch
        recoverySubscriptions.append(useCase.recoveredTranscriptPublisher(for: id).receive(on: DispatchQueue.main).sink { [weak self] frame in
            guard let self, timelineEpoch == epoch, recoveryTaskID == id,
                  useCase.recoveredTranscript(for: id) == frame else { return }
            recoveredTranscript = frame
        })
    }

    func didReadRequest(maxBytes: Int) {
        guard let id = requestTaskID else { return }
        useCase.readRequest(for: id, maxBytes: min(131072, max(1, maxBytes)))
    }

    func didCopyObservationText(_ text: String) {
        copyFeedback = routing.copyToPasteboard(text) ? "Copied" : "Select the displayed text and use your system copy command to copy it."
    }

    func didRequestObservation(_ action: EventObservationAction, taskID: String) {
        guard let frame = observationFrames[taskID] else { return }
        _ = useCase.requestObservation(action, for: taskID, scope: frame.scope)
    }
}
