//
//  NewSessionViewModelMock.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation

// MARK: - NewSessionViewModelMock

/// Preview mock for `NewSessionView`.
@MainActor
final class NewSessionViewModelMock: NewSessionViewModel {
    
    var backend: String
    var repo: String
    var freedom: String
    var message: String
    var errorText: String?
    var isStarting: Bool
    var agentOptions: [BackendTab]
    var agentNotFoundNote: String?
    var agentListUnavailableNote: String?

    var canStart: Bool {
        !isStarting && !backend.isEmpty && !repo.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        backend: String = "claude",
        repo: String = "",
        freedom: String = "read_only",
        message: String = "",
        errorText: String? = nil,
        isStarting: Bool = false,
        agentOptions: [BackendTab] = ["claude", "codex", "opencode", "vibe"].map { BackendTab(id: $0, isNotFound: false) },
        agentNotFoundNote: String? = nil,
        agentListUnavailableNote: String? = nil
    ) {
        self.backend = backend
        self.repo = repo
        self.freedom = freedom
        self.message = message
        self.errorText = errorText
        self.isStarting = isStarting
        self.agentOptions = agentOptions
        self.agentNotFoundNote = agentNotFoundNote
        self.agentListUnavailableNote = agentListUnavailableNote
    }

    func didAppear() {}
    func didDisappear() {}
    func didChangeBackend(_ value: String) { backend = value }
    func didChangeRepo(_ value: String) { repo = value }
    func didChangeFreedom(_ value: String) { freedom = value }
    func didChangeMessage(_ value: String) { message = value }
    func didTapChooseDirectory() {}
    func didTapCancel() {}
    func didTapStart() {}
}

#endif
