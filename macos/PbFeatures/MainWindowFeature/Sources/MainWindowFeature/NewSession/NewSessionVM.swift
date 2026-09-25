//
//  NewSessionVM.swift
//  MainWindowFeature
//

import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbTerminal
import PbUtilities

// MARK: - NewSessionUseCase

/// The New Session sheet's operations over `TaskActionRepository`, `TerminalSessionRegistry` and
/// `ToolEnvironmentRepository`.
@Mockable
@MainActor
protocol NewSessionUseCase: Sendable {
    /// Expands `~`, then validates the result is an absolute path to an existing directory
    /// (F4-44). Returns the resolved path, or `nil` when the exact validation text
    /// "Choose an existing folder." should be shown.
    func resolvedRepoPath(_ input: String) -> String?

    /// Refreshes the listing before returning, so a caller can route to the new task once this
    /// returns (F4-17) — inherited unchanged from `TaskActionRepository.run`.
    func run(_ request: RunRequest) async throws -> String

    @discardableResult
    func startInteractive(backend: String, repo: String) -> Result<TerminalSession, StartInteractiveError>
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
    func didStartInteractive(sessionID: UUID)
    func dismiss()
}

// MARK: - NewSessionVM

/// View model for the New Session sheet, ported from the old `MainView.swift`'s `NewSessionSheet`
/// with no behaviour change: defaults are claude/interactive/read_only with an empty repo/message;
/// interactive disables the message field and ignores freedom; headless needs a non-blank message;
/// success dismisses the sheet; failure stays inline.
@Observable
@MainActor
final class NewSessionVM: NewSessionViewModel {

    // MARK: - NewSessionViewModel Properties

    private(set) var backend = "claude"
    private(set) var repo = ""
    private(set) var interactive = true
    private(set) var freedom = "read_only"
    private(set) var message = ""
    private(set) var errorText: String?
    private(set) var isStarting = false

    var isMessageFieldDisabled: Bool { interactive }
    var canStart: Bool {
        !isStarting && !repo.isEmpty && (interactive || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Private Properties

    @ObservationIgnored private let useCase: any NewSessionUseCase
    @ObservationIgnored private let routing: any NewSessionRouting

    // MARK: - Init

    init(useCase: any NewSessionUseCase, routing: any NewSessionRouting) {
        self.useCase = useCase
        self.routing = routing
    }

    // MARK: - NewSessionViewModel Methods

    func didAppear() {}
    func didDisappear() {}

    func didChangeBackend(_ value: String) { backend = value }
    func didChangeRepo(_ value: String) { repo = value }
    func didChangeInteractive(_ value: Bool) { interactive = value }
    func didChangeFreedom(_ value: String) { freedom = value }
    func didChangeMessage(_ value: String) { message = value }

    func didTapChooseDirectory() {
        Task { [weak self] in
            guard let path = await self?.routing.chooseDirectory() else { return }
            self?.repo = path
        }
    }

    func didTapCancel() {
        routing.dismiss()
    }

    func didTapStart() {
        guard canStart, let path = useCase.resolvedRepoPath(repo) else {
            errorText = "Choose an existing folder."
            return
        }
        errorText = nil

        if interactive {
            switch useCase.startInteractive(backend: backend, repo: path) {
            case .success(let session):
                routing.didStartInteractive(sessionID: session.id)
            case .failure(let error):
                errorText = error.message
            }
            return
        }

        isStarting = true
        let request = RunRequest(backend: backend, repo: path, prompt: message, freedom: freedom)
        // Capture `useCase`/`routing` strongly before awaiting, so the run completes and routes to
        // the new task even if this VM is torn down first (the sheet was dismissed some other way
        // while the request was in flight) — decision 3/F4-17's "capture Routing strongly" rule.
        // Only the failure path touches `self` (to show the error inline), weakly — there is
        // nothing left to show inline if the VM is already gone.
        let capturedUseCase = useCase
        let capturedRouting = routing
        Task { [weak self] in
            do {
                let id = try await capturedUseCase.run(request)
                // Reset `isStarting` before routing, exactly like the old `NewSessionSheet`'s
                // completion handler always did regardless of outcome — moot for the user (the
                // coordinator dismisses the sheet right after), but keeps the VM's own state
                // consistent for as long as it survives.
                self?.isStarting = false
                capturedRouting.didStart(taskID: id)
            } catch {
                self?.isStarting = false
                self?.errorText = (error as? ToolError)?.message ?? "\(error)"
            }
        }
    }
}
