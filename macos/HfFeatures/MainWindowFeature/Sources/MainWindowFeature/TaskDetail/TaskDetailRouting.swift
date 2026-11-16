import Mockable

// MARK: - TaskDetailRouting

/// Navigation the task detail screen performs: moving the selection to an ancestor or a sub-task.
/// A successful `resume` (Continue) does **not** navigate any more (Monitor piece 7): the
/// conversation stays selected, and the new turn appears under it once the listing refreshes.
@Mockable
@MainActor
protocol TaskDetailRouting: Sendable {
    func showNewTask()
    func showResourceSlots()
    func presentStopConfirmation(_ confirmation: TaskStopConfirmation)
    func selectTask(_ taskID: String)
    func publishTopBar(_ content: TaskTopBarContent, tag: TaskTopBarHolder.Tag)
    /// Publishes the loading or not-found state of the task slot (the loaded state travels as content).
    func publishTopBarSlot(_ slot: TaskTopBarSlot, tag: TaskTopBarHolder.Tag)
    func clearTopBar(tag: TaskTopBarHolder.Tag)
    func activateTopBar(tag: TaskTopBarHolder.Tag)
    func deactivateTopBar(tag: TaskTopBarHolder.Tag)
    func retryTopBarActivation(tag: TaskTopBarHolder.Tag)
    /// Writes `text` to the system pasteboard (Monitor piece 3/3's "Copy resume command"),
    /// returning whether the write succeeded. AppKit lives in the coordinator, never the VM — see
    /// `MainWindowCoordinator.chooseDirectory()` for the same pattern.
    func copyToPasteboard(_ text: String) -> Bool
}
