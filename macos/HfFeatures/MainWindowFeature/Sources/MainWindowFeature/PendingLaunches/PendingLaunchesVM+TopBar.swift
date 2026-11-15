import Foundation

// MARK: - Top bar

extension PendingLaunchesVM {
    /// This VM's writer identity for the top bar holder.
    var topBarTag: TaskTopBarHolder.Tag { TaskTopBarHolder.Tag(writer: ObjectIdentifier(self), subject: .pendingLaunches) }

    /// The title for the current screen: the inventory's while no launch is selected, otherwise the detail's own rule
    /// (the launch's qualified title, or "Pending launch").
    var topBarContent: PageTopBarContent {
        guard selection != nil else { return .pendingLaunchesInventory }
        return .pendingLaunches(title: detail?.topBarTitle ?? PendingLaunchesPresentation.neutralRowTitle)
    }

    /// Publishes the current content, then asks to be shown: the bar never shows nothing once the page appears.
    func activateTopBar() {
        lastPublishedTopBar = nil
        publishTopBar()
        topBarRouting?.activateTopBar(tag: topBarTag)
    }

    /// Writes the current content when it changed. The one place every write path reaches.
    func publishTopBar() {
        guard didSubscribe, let topBarRouting else { return }
        topBarRouting.retryTopBarActivation(tag: topBarTag)
        let content = topBarContent
        guard content != lastPublishedTopBar else { return }
        lastPublishedTopBar = content
        topBarRouting.publishTopBar(content, tag: topBarTag)
    }

    /// Withdraws the content; idempotent.
    func deactivateTopBar() {
        lastPublishedTopBar = nil
        topBarRouting?.deactivateTopBar(tag: topBarTag)
        topBarRouting?.clearTopBar(tag: topBarTag)
    }
}
