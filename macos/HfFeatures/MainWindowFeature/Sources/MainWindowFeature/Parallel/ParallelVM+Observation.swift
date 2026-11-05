import HfRepository

extension ParallelVM {
    func applyObservation(_ frame: EventObservationFrame, taskID: String) {
        observationFrames[taskID] = frame
        itemsByTask[taskID] = frame.items
        availabilityByTask[taskID] = frame.presentationAvailability
        history.changedObservation(taskID, frame: frame)
    }

    func adoptObservationWindow(_ id: String) {
        guard let conversation = conversationByID[id], residentIDs.contains(id) else { return }
        let members = Set(conversation.members.map(\.taskID))
        guard !members.contains(where: { id in
            guard let frame = observationFrames[id] else { return false }
            return frame.history.currentness == .sourceChangePending && !frame.history.availableActions.contains(.adoptCurrentSource)
        }) else { return }
        let replacements = members.compactMap { observationFrames[$0] }.filter {
            !$0.history.availableActions.isDisjoint(with: [.adoptCurrentSource, .rebaseWindow])
        }
        if !replacements.isEmpty {
            windowAdoption.willReplace(id: id)
            for frame in replacements {
                let action: EventObservationAction = frame.history.availableActions.contains(.adoptCurrentSource) ? .adoptCurrentSource : .rebaseWindow
                _ = useCase.requestObservation(action, for: frame.taskID, scope: frame.scope)
            }
            return
        }
        windowAdoption.adopt(id: id, frames: observationFrames, members: members)
        resetObservationReadingWindow(id)
        refreshingRetainedIDs.remove(id)
        if let member = conversation.members.first { refreshActivity(memberID: member.taskID) }
    }

    func resetObservationReadingWindow(_ id: String) {
        history.adoptCurrentWindow(id, frames: observationFrames)
        let state = columnState(for: id)
        state.anchor = nil
        state.retainedFirstID = nil
        state.recentFirstID = nil
        state.scrollOffset = 0
        state.viewportPositioned = false
    }

}
