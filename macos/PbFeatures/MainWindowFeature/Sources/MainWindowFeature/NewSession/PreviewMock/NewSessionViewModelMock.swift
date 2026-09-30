//
//  NewSessionViewModelMock.swift
//  MainWindowFeature
//

#if DEBUG

import Foundation
import PbUI

// MARK: - NewSessionViewModelMock

/// Preview mock for `NewSessionView`.
@MainActor
final class NewSessionViewModelMock: NewSessionViewModel {

    var backend: String
    var repo: String
    var freedom: String
    var message: String
    var name = ""
    var model = ""
    var turnLimit = ""
    var turnLimitError: String?
    var effort = ""
    var errorText: String?
    var isStarting: Bool
    var agentCards: [AgentCardModel]
    var recentRepos: [RecentRepoModel]
    var agentNotFoundNote: String?
    var agentListUnavailableNote: String?

    var accessOptions: [AccessOptionModel] {
        [
            ("read_only", "Reads the code and answers. Doesn't change any files. Good for questions and reviews."),
            ("write_in_repo", "Edits files in the repo. Commits and pushes are blocked, so you review before anything leaves."),
            ("publish", "Edits files and may also commit, push and open a PR, if your git and GitHub setup allow it."),
            ("unrestricted", "No limits from polybridge. The agent can touch anything your user account can. Use sparingly.")
        ].map {
            AccessOptionModel(
                id: $0.0, title: AccessLabel.text(freedom: $0.0), detail: $0.1,
                isSelected: $0.0 == freedom, isWarning: $0.0 == "unrestricted"
            )
        }
    }

    var effortOptions: [String] { showsEffort ? ["low", "medium", "high", "xhigh"] : [] }
    var showsEffort: Bool { backend != "vibe" }
    var showsModel: Bool { backend != "vibe" }
    var showsTurnLimit: Bool { true }
    var modelUnavailableNote: String? {
        backend == "vibe" ? "Vibe uses the model set in its own config (~/.vibe/config.toml)." : nil
    }

    var modelChoices: [ModelChoiceModel] {
        [ModelChoiceModel(id: "", title: "Default"), ModelChoiceModel(id: "opus", title: "Opus"), ModelChoiceModel(id: "sonnet", title: "Sonnet")]
    }

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
        notInstalled: Set<String> = [],
        recentRepos: [RecentRepoModel] = [],
        agentNotFoundNote: String? = nil,
        agentListUnavailableNote: String? = nil
    ) {
        self.backend = backend
        self.repo = repo
        self.freedom = freedom
        self.message = message
        self.errorText = errorText
        self.isStarting = isStarting
        self.agentCards = ["claude", "codex", "vibe", "opencode"].map {
            AgentCardModel(
                id: $0, name: BackendStyle.displayName($0), helpText: BackendStyle.helpText($0),
                isSelected: $0 == backend, isNotInstalled: notInstalled.contains($0)
            )
        }
        self.recentRepos = recentRepos
        self.agentNotFoundNote = agentNotFoundNote
        self.agentListUnavailableNote = agentListUnavailableNote
    }

    /// A filled-in sheet for the light and dark previews.
    static var sample: NewSessionViewModelMock {
        NewSessionViewModelMock(
            repo: "~/Code/Carousell-iOS",
            notInstalled: ["opencode"],
            recentRepos: [
                RecentRepoModel(path: "/Users/me/Code/Carousell-iOS", name: "Carousell-iOS", isSelected: false),
                RecentRepoModel(path: "/Users/me/Code/polybridge", name: "polybridge", isSelected: false)
            ]
        )
    }

    func didAppear() {}
    func didDisappear() {}
    func didChangeBackend(_ value: String) { backend = value }
    func didChangeRepo(_ value: String) { repo = value }
    func didChangeFreedom(_ value: String) { freedom = value }
    func didChangeMessage(_ value: String) { message = value }
    func didChangeName(_ value: String) { name = value }
    func didChangeModel(_ value: String) { model = value }
    func didChangeTurnLimit(_ value: String) { turnLimit = value }
    func didChangeEffort(_ value: String) { effort = value }
    func didTapRecentRepo(_ path: String) { repo = path }
    func didTapChooseDirectory() {}
    func didTapCancel() {}
    func didTapStart() {}
}

#endif
