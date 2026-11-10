import Foundation
import MonitorCore

// MARK: - PendingLaunchInventoryReader

/// One traversal's staging is isolated from retained display evidence. Conservative page charges
/// cover the complete128KiB wire envelope, including failures and the single cursor restart.
actor PendingLaunchInventoryReader {
    struct Read: Sendable {
        var rows: [TaskPendingLaunchItem] = []
        var complete = false
        var failure: PendingLaunchFailure?
    }

    private let now: @Sendable () -> ContinuousClock.Instant
    init(now: @escaping @Sendable () -> ContinuousClock.Instant) { self.now = now }

    func read(client: CtlClient) async -> Read {
        let start = now()
        var requests = 0
        var restarts = 0
        var rows: [TaskPendingLaunchItem] = []
        var ids: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        var revision: String?
        var understood = true
        while true {
            guard client.operationIsCurrent(), !Task.isCancelled else { return Read(failure: .superseded) }
            guard requests < 64 else { return Read(rows: rows, failure: .requestBudget) }
            guard now() - start < .seconds(120) else { return Read(rows: rows, failure: .deadline) }
            requests += 1 // 64 *128KiB =8MiB, including the restart and failure documents.
            let response = await client.taskPendingPage(limit: 100, cursor: cursor)
            guard client.operationIsCurrent(), !Task.isCancelled else { return Read(failure: .superseded) }
            guard now() - start < .seconds(120) else { return Read(rows: rows, failure: .deadline) }
            switch response {
            case .failure(let error):
                if cursor != nil, restarts == 0, error.pendingCursorExpired {
                    restarts += 1
                    rows = []; ids = []; cursors = []; cursor = nil; revision = nil; understood = true
                    continue
                }
                return Read(rows: rows, failure: .tool(error))
            case .success(let page):
                if let failure = Self.stage(page, revision: &revision, ids: &ids, rows: &rows) {
                    return Read(rows: rows, failure: failure)
                }
                understood = understood && !page.hasUnsupportedObservations && page.bound == nil
                    && page.invalidNameCount == 0 && page.namespaceComplete
                    && page.items.allSatisfy { $0.disposition == .pending && $0.launch != nil }
                if page.hasMore {
                    guard let next = page.nextCursor, page.examinedCount > 0,
                          cursors.insert(next).inserted else { return Read(rows: rows, failure: .malformed) }
                    cursor = next
                } else {
                    let complete = understood && page.coverage == .complete
                    return Read(rows: rows, complete: complete, failure: complete ? nil : .incomplete)
                }
            }
        }
    }

    private static func stage(_ page: TaskPendingLaunchPage, revision: inout String?, ids: inout Set<String>,
                              rows: inout [TaskPendingLaunchItem]) -> PendingLaunchFailure? {
        guard revision == nil || revision == page.namespaceRevision,
              page.examinedCount >= 0, page.invalidNameCount >= 0,
              page.items.allSatisfy({ !ids.contains($0.taskID) }) else { return .malformed }
        guard rows.count + page.items.count <= 4096 else { return .capacity }
        revision = page.namespaceRevision
        ids.formUnion(page.items.map(\.taskID))
        rows.append(contentsOf: page.items)
        return nil
    }

}

private extension ToolError {
    var pendingCursorExpired: Bool {
        // Structured public code only; diagnostic prose must never trigger a retry.
        switch self {
        case .structuredRefusal(let code, _, _): code == "pending_cursor_expired"
        case .refused(let code, _): code == "pending_cursor_expired"
        default: false
        }
    }
}
