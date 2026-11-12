import Foundation

// MARK: - ParallelVM group top bar

extension ParallelVM {
    /// This VM's writer identity for the top bar holder.
    var topBarTag: TaskTopBarHolder.Tag { TaskTopBarHolder.Tag(writer: ObjectIdentifier(self), subject: .group(groupName)) }

    /// The content before the group's first resolved membership.
    var loadingTopBarContent: GroupTopBarContent { GroupTopBarContent(title: groupName, badge: nil, meta: nil, isLoading: true) }

    /// Publishes the first content, then asks to be shown: the bar never shows nothing between loading and loaded.
    func activateTopBar() {
        guard publishesTopBar else { return }
        lastPublishedTopBar = nil
        publishTopBar(loadingTopBarContent)
        routing.activateTopBar(tag: topBarTag)
    }

    /// Writes `content` when it changed.
    func publishTopBar(_ content: GroupTopBarContent) {
        guard publishesTopBar, didSubscribe else { return }
        routing.retryTopBarActivation(tag: topBarTag)
        guard content != lastPublishedTopBar else { return }
        lastPublishedTopBar = content
        routing.publishTopBar(content, tag: topBarTag)
    }
}
