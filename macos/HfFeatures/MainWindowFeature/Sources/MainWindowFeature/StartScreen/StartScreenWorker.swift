import Foundation
import MonitorCore

// MARK: - StartScreen read results

struct StartScreenReadResult: Sendable {
    var snapshot: StartScreenSnapshot?
    var preparing: Bool
}

struct StartScreenDefinitionsResult: Sendable {
    var definitions: [WorkflowRecord]?
    var presentation: StartScreenPresentation?
    var preparing: Bool
}

// MARK: - StartScreenWorker

/// Keeps structured history reads and immutable presentation computation off the UI executor.
actor StartScreenWorker {
    private struct Read<Value: Sendable>: Sendable {
        var value: Value?
        var preparing: Bool
    }

    private func read<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async -> Read<Value> {
        do {
            let value = try await operation()
            return Read(value: value, preparing: false)
        } catch StartScreenHistoryScanner.ScanError.preparing {
            return Read(value: nil, preparing: true)
        } catch {
            return Read(value: nil, preparing: false)
        }
    }

    func read(source: any StartScreenHistorySource, now: Date, calendar: Calendar,
              onDefinitions: @escaping @Sendable (StartScreenDefinitionsResult) async -> Void) async -> StartScreenReadResult {
        let scanner = StartScreenHistoryScanner(source: source)
        async let tasks = read { try await scanner.scanTasks() }
        async let runs = read { try await scanner.scanWorkflows() }
        async let definitions = readDefinitions(source: source, now: now, calendar: calendar, publish: onDefinitions)
        let (taskItems, runItems, saved) = await (tasks, runs, definitions)
        guard !Task.isCancelled, let definitions = saved.value else {
            return StartScreenReadResult(snapshot: nil, preparing: saved.preparing)
        }
        let preparing = taskItems.preparing || runItems.preparing || saved.preparing
        let snapshot = StartScreenSnapshot(tasks: preparing ? nil : taskItems.value,
                                           runs: preparing ? nil : runItems.value, definitions: definitions)
        return StartScreenReadResult(snapshot: snapshot, preparing: preparing)
    }

    private func readDefinitions(source: any StartScreenHistorySource, now: Date, calendar: Calendar,
                                 publish: @Sendable (StartScreenDefinitionsResult) async -> Void) async -> Read<[WorkflowRecord]> {
        let saved = await read { try await source.definitions() }
        guard !Task.isCancelled else { return saved }
        let presentation = saved.value.map { definitions in
            StartScreenDerivation.make(snapshot: StartScreenSnapshot(tasks: nil, runs: nil, definitions: definitions), now: now, calendar: calendar)
        }
        await publish(StartScreenDefinitionsResult(definitions: saved.value, presentation: presentation, preparing: saved.preparing))
        return saved
    }

    func derive(snapshot: StartScreenSnapshot, now: Date, calendar: Calendar) -> StartScreenPresentation {
        StartScreenDerivation.make(snapshot: snapshot, now: now, calendar: calendar)
    }
}
