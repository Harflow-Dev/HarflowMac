import Combine
import Foundation
import MonitorCore

// MARK: - TaskListRepositoryImpl compatibility and startup

extension TaskListRepositoryImpl {

    public func start() {
        startLock.lock()
        guard !started else { startLock.unlock(); return }
        started = true
        compatibilityGeneration += 1
        let generation = compatibilityGeneration
        startLock.unlock()
        Task {
            _ = await toolEnvironment.discoverEnvironment()
            await checkAndStart(generation: generation)
        }
    }

    func checkAndStart(generation: Int) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        let result = await refreshAndWait()
        guard isCurrent(generation), !Task.isCancelled else { return }
        switch result {
        case .failure: scheduleCompatibilityRetry(generation: generation)
        case .success: startWatching(generation: generation)
        }
    }

    private func scheduleCompatibilityRetry(generation: Int) {
        startLock.lock()
        defer { startLock.unlock() }
        guard started, generation == compatibilityGeneration else { return }
        compatibilityRetryToken?.cancel()
        compatibilityRetryToken = scheduler.schedule(after: 10) { [weak self] in
            guard let self else { return }
            Task { await self.checkAndStart(generation: generation) }
        }
    }

    func isCurrent(_ generation: Int) -> Bool {
        startLock.lock()
        defer { startLock.unlock() }
        return started && generation == compatibilityGeneration
    }

    func refreshGeneration() -> Int {
        startLock.lock()
        defer { startLock.unlock() }
        return compatibilityGeneration
    }

    func refreshIsCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && refreshGeneration() == generation
    }

    func requireCurrentRefresh(_ generation: Int) throws {
        guard refreshIsCurrent(generation) else { throw Self.supersededRefresh }
    }

    static var supersededRefresh: ToolError { WireEnvelope.incompatibility("task listing superseded by selected runtime change") }

    func startWatching(generation: Int) {
        startLock.lock()
        defer { startLock.unlock() }
        guard started, generation == compatibilityGeneration, !Task.isCancelled else { return }
        compatibilityRetryToken?.cancel()
        compatibilityRetryToken = nil
        let watcher = DirectoryWatcher(path: toolEnvironment.tasksDirectory) { [weak self] names in
            guard names.contains(where: RefreshTrigger.isRelevant) else { return }
            self?.scheduleThrottledRefresh()
        }
        watcher.start()
        // A dead owner writes nothing, and the tasks folder may not exist yet: a 10 s safety poll
        // while that matters, and an unconditional reconcile every minute regardless (F4-06).
        // While nothing is visible and nothing needs attention, the cadence stretches to 30 s —
        // three ticks — since nobody is looking; anything busy (running, unreconciled, erroring,
        // bootstrap, dead watcher) keeps its 10 s urgency, and a due 60 s reconcile always wins.
        let token = scheduler.scheduleRepeating(every: 10) { [weak self] in
            guard let self else { return }
            Task {
                await self.evaluateSafetyPoll()
                self.countSafetyPollEvaluation()
            }
        }
        // `watcher` and `pollToken` are set together, under the same lock that guards every other
        // read of `watcher` (`watcherActive`, `restartWatcherIfInactive`) — `pollToken` is written
        // only here, but `startWatching()` runs on whatever thread `start()`'s Task resumes on,
        // which is not guaranteed to be the same thread across calls, so the write still needs the
        // lock for correct publication to any later reader.
        watcherLock.lock()
        self.watcher = watcher
        pollToken = token
        watcherLock.unlock()
    }

    public func settingsChanged() {
        stateRecovery.invalidate()
        runtimeBecameReady()
    }

    public func runtimeBecameReady() {
        startLock.lock()
        compatibilityGeneration += 1
        compatibilityRetryToken?.cancel()
        compatibilityRetryToken = nil
        let generation = compatibilityGeneration
        let shouldStart = started
        watcherLock.lock()
        watcher = nil
        pollToken?.cancel()
        pollToken = nil
        watcherLock.unlock()
        startLock.unlock()
        Task {
            if shouldStart { await checkAndStart(generation: generation) } else { await refresh() }
        }
    }

    // MARK: Refresh (MS-LIST-4/F4-08/F4-09)

}
