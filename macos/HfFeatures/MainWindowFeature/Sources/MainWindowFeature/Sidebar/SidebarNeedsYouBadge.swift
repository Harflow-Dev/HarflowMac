import Combine
import Foundation
import HfRepository
import Mockable

// MARK: - NeedsYouBadge

/// What the Needs you sidebar row shows beside its title. Equality covers every rendered field.
enum NeedsYouBadge: Equatable, Sendable {
    /// Nothing pending: no capsule.
    case none
    /// Before the first complete pass: no capsule.
    case loading
    /// A pending count; `atLeast` when some sources were unread or deferred.
    case count(Int, atLeast: Bool)

    init(_ snapshot: NeedsYouSnapshot) {
        if snapshot.phase == .loading, snapshot.items.isEmpty {
            self = .loading
        } else if snapshot.items.isEmpty {
            self = .none
        } else {
            self = .count(snapshot.items.count, atLeast: snapshot.isLowerBound)
        }
    }

    /// The capsule text, or nil when no capsule is drawn.
    var capsuleText: String? {
        guard case .count(let count, let atLeast) = self else { return nil }
        return atLeast ? "\(count)+" : "\(count)"
    }

    var accessibilityLabel: String {
        switch self {
        case .none: "Needs you, nothing pending"
        case .loading: "Needs you, loading"
        case .count(let count, let atLeast): "Needs you, \(atLeast ? "at least " : "")\(count) pending"
        }
    }
}

// MARK: - SidebarNeedsYouObserving

/// The sidebar's read side of Needs you, kept apart from `SidebarUseCase` like the other observers.
@Mockable
@MainActor
protocol SidebarNeedsYouObserving: Sendable {
    var needsYouBadge: NeedsYouBadge { get }
    func needsYouBadgePublisher() -> AnyPublisher<NeedsYouBadge, Never>
}

// MARK: - SidebarVM

extension SidebarVM {
    var needsYouBadge: NeedsYouBadge {
        get { access(keyPath: \.needsYouBadge); return renderedNeedsYouBadge }
        set {
            guard renderedNeedsYouBadge != newValue else { return }
            withMutation(keyPath: \.needsYouBadge) { renderedNeedsYouBadge = newValue }
            presentationWrites += 1
        }
    }

    func subscribeToNeedsYou() {
        guard let observer = useCase as? any SidebarNeedsYouObserving else { return }
        needsYouBadge = observer.needsYouBadge
        observer.needsYouBadgePublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] badge in self?.needsYouBadge = badge }
            .store(in: &cancellables)
    }
}
