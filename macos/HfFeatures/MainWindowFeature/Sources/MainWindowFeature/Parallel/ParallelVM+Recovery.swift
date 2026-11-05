import Combine
import Foundation

extension ParallelVM {
    func acquireRecovery(_ taskID: String, generation: UUID) {
        recoveryFrames[taskID] = useCase.recoveredTranscript(for: taskID)
        recoveryCancellables[taskID] = useCase.recoveredTranscriptPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                guard let self, leaseGenerations[taskID] == generation,
                      useCase.recoveredTranscript(for: taskID) == frame else { return }
                recoveryFrames[taskID] = frame
                refreshActivity(memberID: taskID)
            }
    }
}
