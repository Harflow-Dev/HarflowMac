// MARK: - RepositoryFieldFlush

/// Lets the composer hand the repository field's undelivered editor bytes to the view model before it reads them
/// (popover dismissal, Start). It only forwards to whichever field coordinator is currently mounted.
@MainActor
final class RepositoryFieldFlush {
    private weak var coordinator: RepositoryPathField.Coordinator?

    func register(_ coordinator: RepositoryPathField.Coordinator) { self.coordinator = coordinator }

    /// A dismantled field must not unregister the field that replaced it.
    func unregister(_ coordinator: RepositoryPathField.Coordinator) {
        if self.coordinator === coordinator { self.coordinator = nil }
    }

    func flush() { coordinator?.flush() }
}
