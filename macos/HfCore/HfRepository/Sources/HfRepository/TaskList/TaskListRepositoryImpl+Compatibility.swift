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
        case .success: startObserving(generation: generation)
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

    func startObserving(generation: Int) {
        startLock.lock()
        guard started, generation == compatibilityGeneration, !Task.isCancelled,
              pollToken == nil, observationStartingGeneration == nil else {
            startLock.unlock()
            return
        }
        observationStartingGeneration = generation
        let previousRetry = compatibilityRetryToken
        compatibilityRetryToken = nil
        startLock.unlock()
        previousRetry?.cancel()

        // A replacement source may synchronously emit its initial invalidation.
        let token = invalidationSource.observe(isUrgent: { [weak self] in
            self?.pollIsUrgent ?? false
        }, onInvalidated: { [weak self] in
            self?.enqueuePoll(generation: generation)
        })
        let installed = startLock.withLock {
            guard started, generation == compatibilityGeneration,
                  observationStartingGeneration == generation, pollToken == nil else { return false }
            observationStartingGeneration = nil
            pollToken = token
            return true
        }
        if !installed { token.cancel() }
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
        observationStartingGeneration = nil
        let previousPoll = pollToken
        pollToken = nil
        startLock.unlock()
        previousPoll?.cancel()
        cancelPreparationRefresh()
        Task {
            if shouldStart { await checkAndStart(generation: generation) } else { await refresh() }
        }
    }

    // MARK: Refresh (MS-LIST-4/F4-08/F4-09)

}
