import Foundation

// MARK: - Repository picker

extension NewSessionVM {
    var isRepoEmpty: Bool { repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    static let missingRepoMessage = "Choose an existing folder."

    func didCommitRepo() {
        guard didSubscribe, !optionsLocked, hasUncommittedRepoEdit else { return }
        hasUncommittedRepoEdit = false
        guard !isRepoEmpty else { return }
        let input = repo
        let path = (input as NSString).expandingTildeInPath
        let generation = repoCheckGeneration
        repoCheckTask = Task { [weak self, useCase] in
            guard !Task.isCancelled else { return }
            let existing = await useCase.existingDirectories(among: [path])
            guard let self, !Task.isCancelled, didSubscribe, !optionsLocked,
                  repoCheckGeneration == generation, repo.utf8.elementsEqual(input.utf8) else { return }
            repoCheckTask = nil
            repoError = existing.contains(path) ? nil : Self.missingRepoMessage
        }
    }

    func cancelRepoCheck() {
        repoCheckGeneration = UUID()
        repoCheckTask?.cancel()
        repoCheckTask = nil
    }

    func didTapRecentRepo(_ path: String) {
        didChangeRepo(path)
        hasUncommittedRepoEdit = false
    }

    func didTapChooseDirectory() {
        guard !optionsLocked else { return }
        Task { [weak self] in
            guard let path = await self?.routing?.chooseDirectory() else { return }
            self?.didTapRecentRepo(path)
        }
    }
}
