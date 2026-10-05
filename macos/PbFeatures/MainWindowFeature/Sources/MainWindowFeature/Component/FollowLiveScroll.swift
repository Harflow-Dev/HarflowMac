import SwiftUI

// MARK: - FollowLiveScroll

private struct FollowLiveScrollKey: Equatable {
    let token: ActivityUpdateToken
    let enabled: Bool
}

extension View {
    /// Coalesces streaming changes after layout and avoids competing scroll animations.
    func followLiveScroll(token: ActivityUpdateToken, enabled: Bool, proxy: ScrollViewProxy, target: String) -> some View {
        task(id: FollowLiveScrollKey(token: token, enabled: enabled)) {
            await Task.yield()
            guard enabled, !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(target, anchor: .bottom) }
        }
    }
}
