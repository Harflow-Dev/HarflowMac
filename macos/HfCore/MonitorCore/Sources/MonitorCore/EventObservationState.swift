import Foundation

// MARK: - EventAvailability

/// Whether a task's event log could actually be read the last time it was tailed — so an empty
/// event list never has to stand for both "nothing has happened yet" and "there is no log to read
/// at all". `.loading` until the first attempt settles one way or the other; a file that exists and
/// opens (even empty, even `/dev/null`) is `.available`, one that cannot be opened at all — missing,
/// or unreadable — is `.unavailable`.
public enum EventAvailability: Equatable, Sendable {
    case loading, available, unavailable
}

// MARK: - EventHistoryState

public struct EventHistoryState: Equatable, Sendable {
    public var hasMore: Bool
    public var isLoading: Bool
    public var error: String?
    public var generation: Int
    public init(hasMore: Bool = false, isLoading: Bool = false, error: String? = nil, generation: Int = 0) {
        self.hasMore = hasMore
        self.isLoading = isLoading
        self.error = error
        self.generation = generation
    }
}
