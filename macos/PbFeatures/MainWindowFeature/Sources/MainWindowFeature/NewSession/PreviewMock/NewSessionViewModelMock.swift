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
    var interactive: Bool
    var freedom: String
    var message: String
    var errorText: String?
    var isStarting: Bool
    
    var isMessageFieldDisabled: Bool { interactive }
    var canStart: Bool { !isStarting && !repo.isEmpty && (interactive || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    
    init(
        backend: String = "claude",
        repo: String = "",
        interactive: Bool = true,
        freedom: String = "read_only",
        message: String = "",
        errorText: String? = nil,
        isStarting: Bool = false
    ) {
        self.backend = backend
        self.repo = repo
        self.interactive = interactive
        self.freedom = freedom
        self.message = message
        self.errorText = errorText
        self.isStarting = isStarting
    }
    
    func didAppear() {}
    func didDisappear() {}
    func didChangeBackend(_ value: String) { backend = value }
    func didChangeRepo(_ value: String) { repo = value }
    func didChangeInteractive(_ value: Bool) { interactive = value }
    func didChangeFreedom(_ value: String) { freedom = value }
    func didChangeMessage(_ value: String) { message = value }
    func didTapChooseDirectory() {}
    func didTapCancel() {}
    func didTapStart() {}
}

#endif
