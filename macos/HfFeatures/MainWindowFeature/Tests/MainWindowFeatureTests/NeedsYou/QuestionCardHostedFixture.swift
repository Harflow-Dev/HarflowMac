import Combine
import Foundation
import HfRepository
@testable import MainWindowFeature

// MARK: - QuestionCardHostedFixture

/// In-memory inputs for real NeedsYouVM hosting; never constructs a repository or engine client.
@MainActor struct QuestionCardHostedFixture {
    static let itemID = "input:fixture-run:fixture-question"
    static let question = "Which environment should this workflow deploy to?"
    let useCase: QuestionCardHostedUseCase
    let routing: QuestionCardHostedRouting
    let vm: NeedsYouVM

    init(offered: Bool = false, text: String = Self.question) {
        let item = NeedsYouItem(id: Self.itemID, kind: .question, rootRunID: "fixture-run", sourceRunID: "fixture-run",
                               runTitle: "Release workflow", pathTitles: ["Release workflow", "Choose environment"], text: text,
                               offeredAnswers: offered ? ["retry", "switch"] : nil,
                               ownership: .init(owner: "monitor", callerEnded: true, engineNote: "Original caller ended", handover: nil),
                               startedBy: "Fixture caller", waitingSince: nil, decisionID: "fixture-question")
        let useCase = QuestionCardHostedUseCase(snapshot: NeedsYouSnapshot(phase: .ready, items: [item]))
        let routing = QuestionCardHostedRouting()
        self.useCase = useCase
        self.routing = routing
        self.vm = NeedsYouVM(useCase: useCase, routing: routing)
    }
}

// MARK: - QuestionCardHostedUseCase

@MainActor final class QuestionCardHostedUseCase: NeedsYouUseCase {
    let subject: CurrentValueSubject<NeedsYouSnapshot, Never>
    var snapshot: NeedsYouSnapshot { subject.value }
    var answerOutcome: NeedsYouAnswerOutcome = .accepted
    private(set) var answerCalls = 0
    private(set) var returnedAnswerCalls = 0
    private(set) var refreshCalls = 0
    private(set) var answers: [(NeedsYouItem, String)] = []
    var holdAnswers = false
    var pendingAnswer: CheckedContinuation<NeedsYouAnswerOutcome, Never>?

    func completeAnswer(_ outcome: NeedsYouAnswerOutcome) {
        let continuation = pendingAnswer
        pendingAnswer = nil
        continuation?.resume(returning: outcome)
    }

    init(snapshot: NeedsYouSnapshot) { self.subject = CurrentValueSubject(snapshot) }
    func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { subject.eraseToAnyPublisher() }
    func refresh() { refreshCalls += 1 }
    func answer(_ item: NeedsYouItem, text: String, additionalAttempts _: Int?) async -> NeedsYouAnswerOutcome {
        answerCalls += 1
        defer { returnedAnswerCalls += 1 }
        answers.append((item, text))
        if holdAnswers { return await withCheckedContinuation { pendingAnswer = $0 } }
        return answerOutcome
    }

    func respond(_: NeedsYouItem, decision _: String) async -> NeedsYouAnswerOutcome { .failed("Unexpected fixture approval") }
}

// MARK: - QuestionCardHostedRouting

@MainActor final class QuestionCardHostedRouting: NeedsYouRouting {
    private(set) var selections: [String?] = []
    private(set) var runs: [String] = []
    func openNeedsYouRun(_ runID: String) { runs.append(runID) }
    func showNeedsYou(itemID: String?) { selections.append(itemID) }
}
