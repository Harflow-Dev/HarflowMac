import Combine
import Foundation
import HfRepository
import SwiftEnvironment

// MARK: - NeedsYouViewRepository

/// Concrete `NeedsYouUseCase` backed by `NeedsYouRepository`.
@MainActor
final class NeedsYouViewRepository: NeedsYouUseCase {
    @GlobalEnvironment(\.needsYouRepository) private var repository

    var snapshot: NeedsYouSnapshot { repository.snapshot }
    func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { repository.snapshotPublisher() }
    func refresh() { repository.refresh() }

    func answer(_ item: NeedsYouItem, text: String, additionalAttempts: Int?) async -> NeedsYouAnswerOutcome {
        await repository.answer(item, text: text, additionalAttempts: additionalAttempts)
    }

    func respond(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome {
        await repository.respond(item, decision: decision)
    }
}
