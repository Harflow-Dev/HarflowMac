//
//  NewSessionVM.swift
//  MainWindowFeature
//

import Combine
import Foundation
import HfCommon
import HfRepository
import HfUI
import HfUtilities
import Mockable
import MonitorCore

// MARK: - NewSessionUseCase

/// The New Session sheet's operations over `TaskActionRepository`.
@Mockable
@MainActor
protocol NewSessionUseCase: Sendable {
    func qualificationSession() -> QualificationSession
    /// Expands `~`, then validates the result is an absolute path to an existing directory
    /// (F4-44). Returns the resolved path, or `nil` when the exact validation text
    /// "Choose an existing folder." should be shown.
    func resolvedRepoPath(_ input: String) -> String?

    /// Refreshes the listing before returning, so a caller can route to the new task once this
    /// returns (F4-17) — inherited unchanged from `TaskActionRepository.run`.
    func run(_ request: RunRequest, runtime: QualificationRuntimeToken) async throws -> String

    /// The current task listing; the VM derives the "Recent" repositories from it.
    var tasks: [TaskInfo] { get }

    // MARK: Backend catalog (Monitor piece 6)

    var agentUsageSnapshot: AgentUsageSnapshot { get }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never>

    var backendCatalog: BackendCatalog { get }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never>

    /// The known models for `backend` (no "Default" entry); empty when there are none or discovery
    /// failed. Never throws and never blocks the caller beyond the discovery itself.
    func models(for backend: String) async -> [ModelOption]
}

extension NewSessionUseCase {
    func qualificationSession() -> QualificationSession { QualificationSession(repository: NullQualificationRepository()) }
    var agentUsageSnapshot: AgentUsageSnapshot { .init() }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { Just(.init()).eraseToAnyPublisher() }
}

// MARK: - NewSessionRouting

/// Navigation and app-shell operations the New Session sheet needs but the VM must not perform
/// itself: `chooseDirectory()` shows an `NSOpenPanel` (AppKit), which belongs in the coordinator
/// (this dispatch's `AGENTS.md`), not the VM.
@Mockable
@MainActor
protocol NewSessionRouting: AnyObject, Sendable {
    func chooseDirectory() async -> String?
    func didStart(taskID: String)
    func dismiss()
    func reviewRecent()
}

extension NewSessionRouting {
    func reviewRecent() {}
}

/// Retained launch boundary; unknown and created cannot be replayed by remounting the composer.
enum ComposerState: Equatable, Sendable {
    case editable, preparing, submitting, refused, unknown, created
}

// MARK: - NewSessionVM

/// View model for the New Session sheet: headless-only. `freedom` defaults to `read_only` with an
/// empty repo/message; a non-blank message and a chosen (non-empty) backend are required to start;
/// success dismisses the sheet, failure stays inline.
///
/// Requested choices survive catalog changes and remain visible until explicitly reviewed.
@Observable
@MainActor
final class NewSessionVM: NewSessionViewModel {

    // MARK: - NewSessionViewModel Properties

    private var qualification: QualificationPresentation?
    @ObservationIgnored private var qualificationTask: Task<Void, Never>?
    var qualificationCards: [QualificationCard] {
        guard !backend.isEmpty else { return [] }
        if let agentNotFoundNote {
            return [.init(id: "unavailable/" + backend, model: .init(identity: BackendStyle.displayName(backend),
                state: .unavailable, message: agentNotFoundNote, features: [], canCheck: false))]
        }
        return qualification?.cards ?? []
    }

    func didTapQualification() {
        guard !optionsLocked, !backend.isEmpty, agentNotFoundNote == nil, let qualification else { return }
        if qualification.isChecking { qualification.cancel() } else { qualification.check() }
    }

    private(set) var backend = ""
    private(set) var repo = ""
    private(set) var freedom = "read_only"
    private(set) var message = ""
    private(set) var name = ""
    private(set) var model = ""
    private(set) var turnLimit = ""
    private(set) var callerApprovals = false
    private(set) var approvalNote: String?
    private var approvalBackends: Set<String> = []
    var supportsCallerApprovals: Bool { approvalBackends.contains(backend) }
    var callerApprovalError: String? {
        guard callerApprovals else { return nil }
        if !supportsCallerApprovals { return "Caller approvals are unavailable for this harness." }
        if !["write_in_repo", "publish"].contains(freedom) { return "Caller approvals require repository write or publish access." }
        if !turnLimit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Caller approvals require an empty turn limit." }
        return nil
    }

    /// The chosen reasoning effort; empty means the agent's default.
    private(set) var effort = ""
    private(set) var errorText: String?
    private(set) var composerState: ComposerState = .editable
    var isStarting: Bool { composerState == .preparing || composerState == .submitting }
    var optionsLocked: Bool { composerState != .editable }
    var canReviewSettings: Bool { composerState == .refused }
    var canReviewRecent: Bool { composerState == .unknown }
    private var requestRevision = UUID()
    private var modelBackend = ""
    private var hasChosenBackend = false
    private var catalogBackendIDs: Set<String> = []
    private var rememberedChoices: [String: Choices] = [:]
    private struct Choices {
        let backend: String
        let model: String
        let modelBackend: String
        let freedom: String
        let effort: String
        let turnLimit: String
        let callerApprovals: Bool
    }

    var validationMessages: [String] {
        var messages: [String] = []
        if !backend.isEmpty, !catalogBackendIDs.contains(backend) {
            messages.append("The requested harness is unavailable. Choose a harness explicitly.")
        }
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !showsModel {
                messages.append("This harness does not accept a model option. Choose Default explicitly.")
            } else if modelBackend != backend {
                messages.append("Review and select the model for this harness.")
            }
        }
        if !effort.isEmpty, !effortOptions.contains(effort) { messages.append("The requested effort is unsupported by this harness.") }
        if !Self.freedomLevels.contains(where: { $0.id == freedom }) { messages.append("The requested access is unsupported.") }
        if let turnLimitError { messages.append(turnLimitError) }
        if let callerApprovalError { messages.append(callerApprovalError) }
        return messages
    }

    private(set) var agentOptions: [BackendTab] = []
    /// "<backend> wasn't found on your PATH — starting it may fail." (Review round 2's wording) when
    /// the currently selected backend is a confirmed not-found one; `nil` otherwise.
    private(set) var agentNotFoundNote: String?
    /// "Backend list unavailable — update harflow." when the catalog is degraded with nothing
    /// carried over, so `agentOptions` is showing the `BackendStyle.known` display fallback rather
    /// than anything harflow actually reported.
    private(set) var agentListUnavailableNote: String?

    /// The agent options as selectable cards.
    var agentCards: [AgentCardModel] {
        agentOptions.map {
            AgentCardModel(
                id: $0.id, name: BackendStyle.displayName($0.id), helpText: BackendStyle.helpText($0.id),
                isSelected: $0.id == backend, isNotInstalled: $0.isNotFound
            )
        }
    }

    /// Up to `Self.recentRepoLimit` distinct repositories from the task list, most recent first.
    var recentRepos: [RecentRepoModel] {
        recentRepoPaths.map { RecentRepoModel(path: $0, name: Format.repoName($0), isSelected: $0 == repo) }
    }

    /// The four `freedom` levels as radio rows, in increasing order of power.
    var accessOptions: [AccessOptionModel] {
        Self.freedomLevels.map { level in
            AccessOptionModel(
                id: level.id, title: AccessLabel.text(freedom: level.id), detail: level.detail,
                isSelected: level.id == freedom, isWarning: level.id == "unrestricted"
            )
        }
    }

    /// Vibe keeps effort in its own config. Cursor has no effort flag, so its level list is empty.
    var showsEffort: Bool { backend != "vibe" && !BackendStyle.effortLevels(backend).isEmpty }
    /// The Model combo's suggestions: "Default" (the agent's own model, an empty value) first, then
    /// the agent's known models. Only "Default" until a discovery finishes or when there are none.
    var modelChoices: [ModelChoiceModel] {
        [ModelChoiceModel(id: "", title: "Default")] + modelOptions.map { ModelChoiceModel(id: $0.value, title: $0.label) }
    }

    /// Vibe rejects a model outright: its model is chosen in its own config.
    var showsModel: Bool { backend != "vibe" }
    /// Shown in place of the Model control for an agent that takes no model from harflow (vibe).
    var modelUnavailableNote: String? {
        backend == "vibe" ? "Vibe uses the model set in its own config (~/.vibe/config.toml)." : nil
    }

    /// Only agents harflow can cap (claude, vibe). Cursor has no turn-cap flag.
    var showsTurnLimit: Bool { BackendStyle.supportsTurnLimit(backend) }
    /// The effort levels offered for the chosen backend: antigravity takes only `low`/`medium`/
    /// `high` (it refuses `xhigh`), cursor takes none, and the others take harflow's full
    /// vocabulary. The table lives in `BackendStyle`; unsupported requested effort remains
    /// visible for review and blocks Start.
    var effortOptions: [String] { showsEffort ? BackendStyle.effortLevels(backend) : [] }

    var canStart: Bool {
        agentNotFoundNote == nil && qualification?.isReady == true && !optionsLocked && validationMessages.isEmpty && !backend.isEmpty && !repo.isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && turnLimitError == nil && callerApprovalError == nil
    }

    /// The typed turn limit: blank means the agent's default; anything else must be a whole number
    /// above zero, or the session would silently start without the cap the user asked for.
    var parsedTurnLimit: Int? {
        Int(turnLimit.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Why Start is held back by the Turn limit field, or `nil` when it is blank, valid or hidden.
    var turnLimitError: String? {
        guard !turnLimit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !showsTurnLimit { return "The requested turn limit is unsupported by this harness." }
        guard parsedTurnLimit == nil else { return nil }
        return "Enter a whole number above 0, or leave it empty for the default."
    }

    // MARK: - Constants

    static let recentRepoLimit = 5
    /// The four real access options, in increasing order of power. Each description states the
    /// authority the dispatch REQUESTS — never a restriction guarantee for a harness that does
    /// not enforce one; the single verbatim enforcement caveat in the view carries how strictly
    /// any of it is actually enforced, and there is deliberately no second VM caption.
    private static let freedomLevels: [(id: String, detail: String)] = [
        ("read_only", "Requests read-only repo review."),
        ("write_in_repo", "Requests repo edits, no publishing."),
        ("publish", "Requests edits and publish attempts."),
        ("unrestricted", "Requests broad access; use sparingly.")
    ]

    // MARK: - Private Properties

    private var recentRepoPaths: [String] = []
    private var modelOptions: [ModelOption] = []
    private var usage = AgentUsageSnapshot()
    @ObservationIgnored private let useCase: any NewSessionUseCase
    @ObservationIgnored private weak var routing: (any NewSessionRouting)?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var modelsTask: Task<Void, Never>?

    // MARK: - Init

    init(useCase: any NewSessionUseCase, routing: any NewSessionRouting) {
        self.useCase = useCase
        self.routing = routing
        self.usage = useCase.agentUsageSnapshot
        applyCatalog(useCase.backendCatalog)
        refreshRecentRepos()
    }

    // MARK: - NewSessionViewModel Methods

    func didAppear() {
        if qualification == nil { qualification = QualificationPresentation(session: useCase.qualificationSession()) }
        refreshQualification()
        refreshRecentRepos()
        subscribeIfNeeded()
        loadModels()
    }

    func didDisappear() {
        qualificationTask?.cancel()
        qualification?.stop()
        cancellables.removeAll()
        didSubscribe = false
        modelsTask?.cancel()
        modelsTask = nil
    }

    func didChangeBackend(_ value: String) {
        guard !optionsLocked else { return }
        let previous = backend
        backend = value
        hasChosenBackend = true
        recomputeAgentNotFoundNote()
        if value != previous { agentDidChange() }
        refreshQualification()
    }

    func didChangeRepo(_ value: String) {
        guard !optionsLocked else { return }
        repo = value
        if let choices = rememberedChoices[value] {
            backend = choices.backend; model = choices.model; modelBackend = choices.modelBackend
            freedom = choices.freedom; effort = choices.effort; turnLimit = choices.turnLimit
            callerApprovals = choices.callerApprovals; hasChosenBackend = true
            recomputeAgentNotFoundNote(); agentDidChange()
        }
        refreshQualification()
    }

    func didChangeFreedom(_ value: String) { guard !optionsLocked else { return }; freedom = value; refreshQualification() }
    func didChangeMessage(_ value: String) { guard !optionsLocked else { return }; message = value; refreshQualification() }
    func didChangeName(_ value: String) { guard !optionsLocked else { return }; name = value; refreshQualification() }
    func didChangeModel(_ value: String) { guard !optionsLocked else { return }; model = value; modelBackend = backend; refreshQualification() }
    func didChangeTurnLimit(_ value: String) { guard !optionsLocked else { return }; turnLimit = value; refreshQualification() }
    func didChangeCallerApprovals(_ value: Bool) { guard !optionsLocked else { return }; callerApprovals = value; approvalNote = nil; refreshQualification() }
    func didChangeEffort(_ value: String) { guard !optionsLocked else { return }; effort = value; refreshQualification() }
    func didTapRecentRepo(_ path: String) { didChangeRepo(path) }

    func didTapChooseDirectory() {
        guard !optionsLocked else { return }
        Task { [weak self] in
            guard let path = await self?.routing?.chooseDirectory() else { return }
            self?.didChangeRepo(path)
        }
    }

    func didTapCancel() {
        if composerState == .editable { qualification?.stop() }
        routing?.dismiss()
    }

    func didTapReviewSettings() {
        guard canReviewSettings else { return }
        composerState = .editable
        errorText = nil
        refreshQualification()
    }

    func didTapReviewRecent() {
        guard canReviewRecent else { return }
        routing?.reviewRecent()
    }

    /// Only an explicit new-task intent may clear an acknowledged, terminal composer.
    func prepareForNewTask() {
        guard composerState == .created else { return }
        composerState = .editable
        message = ""; name = ""; errorText = nil
        refreshQualification()
    }

    func didTapStart() {
        guard !optionsLocked else { return }
        guard canStart else { return }
        guard let path = useCase.resolvedRepoPath(repo) else {
            errorText = "Choose an existing folder."
            return
        }
        guard let qualification, let routing else { return }
        errorText = nil
        qualificationTask?.cancel()
        let revision = requestRevision
        let request = makeRequest(repo: path)
        // Start adopts even a loading-catalog default as an explicit submitted choice.
        hasChosenBackend = true
        composerState = .preparing
        Task { [self, useCase, routing] in
            guard await qualification.discover(Self.qualificationRequest(request)),
                  let runtime = qualification.runtime,
                  requestRevision == revision, makeRequest(repo: path) == request,
                  composerState == .preparing else {
                if composerState == .preparing {
                    composerState = .editable
                    errorText = "Qualification is unavailable or changed. Review the request before starting."
                }
                return
            }
            // The immutable request, revision and runtime token cross this boundary exactly once.
            rememberedChoices[path] = Choices(backend: backend, model: model, modelBackend: modelBackend,
                freedom: freedom, effort: effort, turnLimit: turnLimit, callerApprovals: callerApprovals)
            composerState = .submitting
            do {
                let id = try await useCase.run(request, runtime: runtime)
                guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    composerState = .unknown
                    errorText = "No task identity was acknowledged. A task may exist. Review Recent work before any further action."
                    return
                }
                composerState = .created
                routing.didStart(taskID: id)
            } catch {
                // Only the public launch-refusal code exercised by ctl-launch-run-refused is
                // classified. Unknown codes, transport failures and list-refresh failure stay locked.
                if case ToolError.refused(code: "invalid_params", message: _) = error {
                    composerState = .refused
                } else {
                    composerState = .unknown
                }
                errorText = (error as? ToolError)?.message ?? "\(error)"
                if composerState == .unknown {
                    errorText = (errorText ?? "") + " A task may exist. Review Recent work; do not start it again."
                }
            }
        }
    }

    // MARK: - Private Methods

    private static func qualificationRequest(_ request: RunRequest) -> QualificationRequest {
        // permission-preview accepts authority fields only. Revision and full-request equality
        // still fence every draft option, including model, effort, title, prompt and turn limit.
        var options = ["--backend=\(request.backend)", "--repo=\(request.repo)"]
        if let freedom = request.freedom { options.append("--freedom=\(freedom)") }
        if request.callerApprovals { options.append("--caller-approvals") }
        return .task(options: options)
    }

    private func refreshQualification() {
        guard composerState == .editable else { return }
        requestRevision = UUID()
        qualificationTask?.cancel()
        guard let qualification else { return }
        guard !backend.isEmpty, agentNotFoundNote == nil, validationMessages.isEmpty else { qualification.stop(); return }
        let request = makeRequest(repo: repo)
        qualification.prepare(request: Self.qualificationRequest(request))
        qualificationTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = await qualification.discover(Self.qualificationRequest(request))
        }
    }

    /// Empty optional fields become `nil`, so they are never passed to `ctl run` (an invalid turn
    /// limit never gets here: it holds `canStart` back).
    private func makeRequest(repo path: String) -> RunRequest {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return RunRequest(
            backend: backend, repo: path, prompt: message, freedom: freedom,
            reasoningEffort: effort.isEmpty ? nil : effort,
            title: trimmedName.isEmpty ? nil : trimmedName,
            model: trimmedModel.isEmpty ? nil : trimmedModel,
            maxTurns: parsedTurnLimit, callerApprovals: callerApprovals
        )
    }

    /// Refresh suggestions without changing the requested model or its harness provenance.
    private func agentDidChange() {
        modelOptions = []
        loadModels()
    }

    /// Requests the current agent's model list without blocking the sheet; an answer that arrives
    /// after the agent changed again is dropped.
    private func loadModels() {
        modelsTask?.cancel()
        let requested = backend
        guard showsModel else {
            modelOptions = []
            return
        }
        modelsTask = Task { [weak self, useCase] in
            let options = await useCase.models(for: requested)
            guard !Task.isCancelled, let self, backend == requested else { return }
            let ranked = await Task.detached { [usage = useCase.agentUsageSnapshot] in usage.rankedModels(options, backend: requested) }.value
            guard !Task.isCancelled, backend == requested else { return }
            if modelOptions != ranked { modelOptions = ranked }
        }
    }

    private func refreshRecentRepos() {
        var seen = Set<String>()
        recentRepoPaths = useCase.tasks
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            .map(\.repoPath)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(Self.recentRepoLimit)
            .map(\.self)
    }

    // MARK: - Private Methods (Monitor piece 6)

    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        useCase.agentUsagePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                guard let self, self.usage != usage else { return }
                self.usage = usage
                rankAgentOptions()
                loadModels()
            }
            .store(in: &cancellables)
        useCase.backendCatalogPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] catalog in self?.applyCatalog(catalog) }
            .store(in: &cancellables)
    }

    /// Only initial selection may default. Later catalog loss keeps the requested harness visible.
    private func applyCatalog(_ catalog: BackendCatalog) {
        // An in-flight preflight must not launch using a catalog snapshot it no longer owns.
        if composerState == .preparing { requestRevision = UUID() }
        catalogBackendIDs = Set(Self.computeAgentOptions(from: catalog).options.map(\.id))
        approvalBackends = catalog.state == .available ? Set(catalog.entries.filter(\.supportsCallerApprovals).map(\.backend)) : []
        let (options, unavailableNote) = Self.computeAgentOptions(from: catalog)
        let order = usage.rankedBackends(options.map(\.id))
        let ranked = order.compactMap { id in options.first { $0.id == id } }
        if agentOptions != ranked { agentOptions = ranked }
        agentListUnavailableNote = unavailableNote
        let previous = backend
        if composerState == .editable, !hasChosenBackend, backend.isEmpty || catalog.state == .available {
            backend = agentOptions.first?.id ?? ""
            if catalog.state == .available { hasChosenBackend = true }
        }
        if !backend.isEmpty, !agentOptions.contains(where: { $0.id == backend }) {
            agentOptions.append(BackendTab(id: backend, isNotFound: true))
        }
        recomputeAgentNotFoundNote()
        if backend != previous, didSubscribe { agentDidChange() }
        if didSubscribe, composerState == .editable { refreshQualification() }
    }

    // Catalogs contain a bounded handful of harnesses; this pure presentation ordering never
    // reconciles selection or changes a submitted request.
    private func rankAgentOptions() {
        let order = usage.rankedBackends(agentOptions.map(\.id))
        let ranked = order.compactMap { id in agentOptions.first { $0.id == id } }
        if agentOptions != ranked { agentOptions = ranked }
    }

    private func recomputeAgentNotFoundNote() {
        if !backend.isEmpty, !catalogBackendIDs.contains(backend) {
            if !agentOptions.contains(where: { $0.id == backend }) {
                agentOptions.append(BackendTab(id: backend, isNotFound: true))
            }
            agentNotFoundNote = "The requested harness \(backend) is unavailable in the current catalog. Choose a harness explicitly."
            return
        }
        guard let option = agentOptions.first(where: { $0.id == backend }), option.isNotFound else {
            agentNotFoundNote = nil
            return
        }
        agentNotFoundNote = "\(backend) wasn't found on your PATH — starting this harness may fail."
    }

    /// Design's New Session section: every backend harflow reports, in registry order; while
    /// loading, or when degraded with nothing carried over, falls back to `BackendStyle.known` so
    /// the picker is never empty — flagged with `agentListUnavailableNote` in the degraded case only
    /// (loading is not yet known to be unavailable, so it says nothing).
    private static func computeAgentOptions(from catalog: BackendCatalog) -> (options: [BackendTab], note: String?) {
        switch catalog.state {
        case .available:
            return (catalog.entries.map { BackendTab(id: $0.backend, isNotFound: $0.installed == false) }, nil)
        case .degraded:
            guard catalog.entries.isEmpty else {
                return (catalog.entries.map { BackendTab(id: $0.backend, isNotFound: false) }, nil)
            }
            return (BackendStyle.known.map { BackendTab(id: $0, isNotFound: false) }, "Harness list unavailable — update harflow.")
        case .loading:
            return (BackendStyle.known.map { BackendTab(id: $0, isNotFound: false) }, nil)
        }
    }
}
