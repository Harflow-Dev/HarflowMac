// MARK: - ParallelColumnModelBuilder

/// Maps retained activity and fresh metadata without accessing leases or mutable VM state.
enum ParallelColumnModelBuilder {
    static func build(presentation: ParallelColumnPresentation, metadata: ParallelColumnPresentation,
                      onTapTakeover: @escaping () -> Void, onTapOpenTask: @escaping () -> Void,
                      onSelectTask: ((String) -> Void)? = nil) -> ParallelColumnModel {
        var column = ParallelColumnModel(id: presentation.id, task: metadata.task, title: metadata.title,
            subtitle: metadata.subtitle, isBusy: metadata.isBusy, outcomeMessage: metadata.outcomeMessage,
            showPrompt: metadata.showPrompt, prompt: presentation.prompt, rows: presentation.rows,
            activityRows: presentation.activityRows, liveStep: presentation.liveStep,
            pendingMessages: presentation.pendingMessages, isLoading: presentation.isLoading, summary: presentation.summary,
            stepCountText: presentation.stepCountText, noToolCallsText: presentation.noToolCallsText,
            onTapTakeover: onTapTakeover, onTapOpenTask: onTapOpenTask, start: presentation.start)
        column.emptyText = presentation.emptyText
        column.onSelectTask = onSelectTask
        column.memberTaskIDs = metadata.memberTaskIDs
        column.history = presentation.history
        column.paginationRevision = presentation.paginationRevision
        return column
    }
}
