import Foundation

// MARK: - PublicEventObservationAdmission

/// Cancellable queued admission. Running work retains its permit until actual completion.
protocol PublicEventObservationAdmission: Sendable {
    func submit(id: UUID, work: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void)
    func cancel(_ id: UUID)
}

extension EventInitialLoadQueue: PublicEventObservationAdmission {}
