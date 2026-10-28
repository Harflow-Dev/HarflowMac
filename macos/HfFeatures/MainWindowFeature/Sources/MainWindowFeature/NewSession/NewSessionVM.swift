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
protocol NewSessionRouting: Sendable {
    func chooseDirectory() async -> String?
    func didStart(taskID: String)
    func dismiss()
}

// MARK: - NewSessionVM

/// View model for the New Session sheet: headless-only. `freedom` defaults to `read_only` with an
/// empty repo/message; a non-blank message and a chosen (non-empty) backend are required to start;
/// success dismisses the sheet, failure stays inline.
///
/// **Agent picker (Monitor piece 6).** `backend`'s default no longer hardcodes `"claude"` — it comes
/// from the backends catalog (`BackendsRepository`, via `NewSessionUseCase`), kept live for as long
/// as the sheet is open (Design's New Session section + Review round 2's selection reconciliation):
/// the previously-selected backend survives a catalog replacement while it's still listed; otherwise
/// selection falls to the catalog's first entry; an empty **successful** catalog (`state == .available`
/// with no entries) clears `backend` and disables Start, so the sheet can never submit a backend it
/// isn't even showing. `HfUI.BackendStyle.known` is used only as New Session's own degraded-mode
/// display fallback (Design: "flagged 'list unavailable'"), while loading and whenever the catalog is
/// degraded with nothing carried over — never as a hardcoded default.
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
        guard !backend.isEmpty, agentNotFoundNote == nil, let qualification else { return }
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
    private(set) var isStarting = false
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
    /// vocabulary. The table lives in `BackendStyle`, and `didChangeBackend` resets an effort
    /// the new backend does not offer.
    var effortOptions: [String] { showsEffort ? BackendStyle.effortLevels(backend) : [] }

    var canStart: Bool {
        agentNotFoundNote == nil && qualification?.isReady == true && !isStarting && !backend.isEmpty && !repo.isEmpty
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
        guard showsTurnLimit, !turnLimit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, parsedTurnLimit == nil else { return nil }
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
    @ObservationIgnored private let routing: any NewSessionRouting
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
        let previous = backend
        backend = value
        if !effortOptions.contains(effort) { effort = "" }
        recomputeAgentNotFoundNote()
        if value != previous { agentDidChange() }
        refreshQualification()
    }

    func didChangeRepo(_ value: String) { repo = value; refreshQualification() }
    func didChangeFreedom(_ value: String) { freedom = value; refreshQualification() }
    func didChangeMessage(_ value: String) { message = value; refreshQualification() }
    func didChangeName(_ value: String) { name = value; refreshQualification() }
    func didChangeModel(_ value: String) { model = value; refreshQualification() }
    func didChangeTurnLimit(_ value: String) { turnLimit = value; refreshQualification() }
    func didChangeCallerApprovals(_ value: Bool) { callerApprovals = value && supportsCallerApprovals; approvalNote = nil; refreshQualification() }
    func didChangeEffort(_ value: String) { effort = effortOptions.contains(value) ? value : ""; refreshQualification() }
    func didTapRecentRepo(_ path: String) { repo = path; refreshQualification() }

    func didTapChooseDirectory() {
        Task { [weak self] in
            guard let path = await self?.routing.chooseDirectory() else { return }
            self?.repo = path
            self?.refreshQualification()
        }
    }

    func didTapCancel() {
        qualification?.stop()
        routing.dismiss()
    }

    func didTapStart() {
        guard canStart, let path = useCase.resolvedRepoPath(repo) else {
            errorText = "Choose an existing folder."
            return
        }
        errorText = nil

        isStarting = true
        let request = makeRequest(repo: path)
        // Capture `useCase`/`routing` strongly before awaiting, so the run completes and routes to
        // the new task even if this VM is torn down first (the sheet was dismissed some other way
        // while the request was in flight) — decision 3/F4-17's "capture Routing strongly" rule.
        // Only the failure path touches `self` (to show the error inline), weakly — there is
        // nothing left to show inline if the VM is already gone.
        guard let qualification else { isStarting = false; return }
        let capturedUseCase = useCase
        let capturedRouting = routing
        Task { [weak self] in
            do {
                guard await qualification.discover(Self.qualificationRequest(request)),
                      let self, let runtime = qualification.runtime, makeRequest(repo: path) == request, isStarting else {
                    self?.isStarting = false
                    return
                }
                let id = try await capturedUseCase.run(request, runtime: runtime)
                // Reset `isStarting` before routing, exactly like the old `NewSessionSheet`'s
                // completion handler always did regardless of outcome — moot for the user (the
                // coordinator dismisses the sheet right after), but keeps the VM's own state
                // consistent for as long as it survives.
                isStarting = false
                capturedRouting.didStart(taskID: id)
            } catch {
                self?.isStarting = false
                self?.errorText = (error as? ToolError)?.message ?? "\(error)"
            }
        }
    }

    // MARK: - Private Methods

    private static func qualificationRequest(_ request: RunRequest) -> QualificationRequest {
        var options = ["--backend=\(request.backend)", "--repo=\(request.repo)"]
        if let freedom = request.freedom { options.append("--freedom=\(freedom)") }
        if request.callerApprovals { options.append("--caller-approvals") }
        return .task(options: options)
    }

    private func refreshQualification() {
        qualificationTask?.cancel()
        guard let qualification else { return }
        guard !backend.isEmpty, agentNotFoundNote == nil else { qualification.stop(); return }
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
            reasoningEffort: effortOptions.contains(effort) ? effort : nil,
            title: trimmedName.isEmpty ? nil : trimmedName,
            model: showsModel && !trimmedModel.isEmpty ? trimmedModel : nil,
            maxTurns: showsTurnLimit ? parsedTurnLimit : nil, callerApprovals: callerApprovals
        )
    }

    /// A model typed or picked for one agent means nothing to another, so it is cleared (like effort
    /// for vibe), and the new agent's suggestions are requested.
    private func agentDidChange() {
        if callerApprovals, !supportsCallerApprovals {
            callerApprovals = false
            approvalNote = "Caller approvals were cleared because the selected harness does not support them."
        }
        model = ""
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

    /// Review round 2's reconciliation: keep the selected backend while it's still in the new
    /// catalog; otherwise fall to the catalog's first entry — or to nothing at all when the catalog
    /// is empty, which is what disables Start.
    private func applyCatalog(_ catalog: BackendCatalog) {
        let previousNotFoundNote = agentNotFoundNote
        approvalBackends = catalog.state == .available ? Set(catalog.entries.filter(\.supportsCallerApprovals).map(\.backend)) : []
        let (options, unavailableNote) = Self.computeAgentOptions(from: catalog)
        let order = usage.rankedBackends(options.map(\.id))
        let ranked = order.compactMap { id in options.first { $0.id == id } }
        if agentOptions != ranked { agentOptions = ranked }
        agentListUnavailableNote = unavailableNote
        let previous = backend
        if !options.contains(where: { $0.id == backend }) {
            backend = agentOptions.first?.id ?? ""
        }
        recomputeAgentNotFoundNote()
        if backend != previous, didSubscribe {
            agentDidChange()
            refreshQualification()
        } else if didSubscribe, previousNotFoundNote != agentNotFoundNote {
            refreshQualification()
        }
    }

    // Catalogs contain a bounded handful of harnesses; this pure presentation ordering never
    // reconciles selection or changes a submitted request.
    private func rankAgentOptions() {
        let order = usage.rankedBackends(agentOptions.map(\.id))
        let ranked = order.compactMap { id in agentOptions.first { $0.id == id } }
        if agentOptions != ranked { agentOptions = ranked }
    }

    private func recomputeAgentNotFoundNote() {
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
