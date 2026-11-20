import HfCommon
import HfUI
@testable import MainWindowFeature
import MonitorCore

/// Forwards the production view-model contract while recording every repository binding write from the view.
@MainActor
final class RepositoryBindingObservedViewModel: NewSessionViewModel {
    let viewModel: NewSessionVM
    private(set) var repositoryWrites: [String] = []
    /// Ordered record of the repository writes, commits, Start taps and lifecycle calls the view made.
    private(set) var events: [String] = []
    /// `repo` as the view model held it on entry to each `didCommitRepo`.
    private(set) var repoAtCommit: [String] = []
    private(set) var startTapCount = 0
    /// Runs on entry to `didCommitRepo`, so a test can sample view state at that moment.
    var commitProbe: (@MainActor () -> Void)?
    /// Runs on entry to `didChangeRepo`, before the write is recorded.
    var writeProbe: (@MainActor () -> Void)?

    init(_ model: NewSessionVM) { self.viewModel = model }

    var composerState: ComposerState { viewModel.composerState }
    var optionsLocked: Bool { viewModel.optionsLocked }
    var validationMessages: [String] { viewModel.validationMessages }
    var canReviewSettings: Bool { viewModel.canReviewSettings }
    var canReviewRecent: Bool { viewModel.canReviewRecent }
    var qualificationCards: [QualificationCard] { viewModel.qualificationCards }
    var backend: String { viewModel.backend }
    var repo: String { viewModel.repo }
    var repoSelectionGeneration: Int { viewModel.repoSelectionGeneration }
    var isRepoEmpty: Bool { viewModel.isRepoEmpty }
    var repoError: String? { viewModel.repoError }
    var freedom: String { viewModel.freedom }
    var message: String { viewModel.message }
    var name: String { viewModel.name }
    var model: String { viewModel.model }
    var turnLimit: String { viewModel.turnLimit }
    var callerApprovals: Bool { viewModel.callerApprovals }
    var supportsCallerApprovals: Bool { viewModel.supportsCallerApprovals }
    var callerApprovalError: String? { viewModel.callerApprovalError }
    var approvalNote: String? { viewModel.approvalNote }
    var turnLimitError: String? { viewModel.turnLimitError }
    var effort: String { viewModel.effort }
    var errorText: String? { viewModel.errorText }
    var isStarting: Bool { viewModel.isStarting }
    var canStart: Bool { viewModel.canStart }
    var agentCards: [AgentCardModel] { viewModel.agentCards }
    var recentRepos: [RecentRepoModel] { viewModel.recentRepos }
    var accessOptions: [AccessOptionModel] { viewModel.accessOptions }
    var effortOptions: [String] { viewModel.effortOptions }
    var showsEffort: Bool { viewModel.showsEffort }
    var showsModel: Bool { viewModel.showsModel }
    var modelChoices: [ModelChoiceModel] { viewModel.modelChoices }
    var modelNote: ModelListingNote? { viewModel.modelNote }
    var showsTurnLimit: Bool { viewModel.showsTurnLimit }
    var agentNotFoundNote: String? { viewModel.agentNotFoundNote }
    var agentListUnavailableNote: String? { viewModel.agentListUnavailableNote }

    func didTapReviewSettings() { viewModel.didTapReviewSettings() }
    func didTapReviewRecent() { viewModel.didTapReviewRecent() }
    func didTapQualification() { viewModel.didTapQualification() }
    func didChangeCallerApprovals(_ value: Bool) { viewModel.didChangeCallerApprovals(value) }
    func didTapRetryModels() { viewModel.didTapRetryModels() }
    func didAppear() {
        events.append("appear")
        viewModel.didAppear()
    }

    func didDisappear() {
        events.append("disappear")
        viewModel.didDisappear()
    }

    func didChangeBackend(_ value: String) { viewModel.didChangeBackend(value) }
    func didChangeRepo(_ value: String) {
        writeProbe?()
        repositoryWrites.append(value)
        events.append("write:" + value)
        viewModel.didChangeRepo(value)
    }

    func didCommitRepo() {
        repoAtCommit.append(viewModel.repo)
        events.append("commit:" + viewModel.repo)
        commitProbe?()
        viewModel.didCommitRepo()
    }

    func didChangeFreedom(_ value: String) { viewModel.didChangeFreedom(value) }
    func didChangeMessage(_ value: String) { viewModel.didChangeMessage(value) }
    func didChangeName(_ value: String) { viewModel.didChangeName(value) }
    func didChangeModel(_ value: String) { viewModel.didChangeModel(value) }
    func didChangeTurnLimit(_ value: String) { viewModel.didChangeTurnLimit(value) }
    func didChangeEffort(_ value: String) { viewModel.didChangeEffort(value) }
    func didTapRecentRepo(_ path: String) { viewModel.didTapRecentRepo(path) }
    func didOpenRepositoryPicker() { viewModel.didOpenRepositoryPicker() }
    func didTapChooseDirectory() { viewModel.didTapChooseDirectory() }
    func didTapCancel() { viewModel.didTapCancel() }
    func didTapStart() {
        startTapCount += 1
        events.append("start")
        viewModel.didTapStart()
    }
}
