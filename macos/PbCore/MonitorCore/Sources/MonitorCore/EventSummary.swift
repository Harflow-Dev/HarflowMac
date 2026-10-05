import Foundation

public struct EventSummary: Equatable, Sendable {
    public var files: [EditedFile] = []
    public var totalFiles = 0
    public var fileSequences: [String: Int] = [:]
    public var activity = ActivityCounts()
    public var prompt: String?
    public var availability: EventAvailability = .loading
    public init() {}
}

/// Cumulative projection keeps only paths and unresolved edit identities, never raw history.
public struct EventSummaryBuilder: Sendable {
    private var repoPath = ""
    private var order: [String] = []
    private var latest: [String: (String, EditedFileStatus)] = [:]
    private var sequences: [String: Int] = [:]
    private var pending: [String: String] = [:]
    private var value = EventSummary()
    public var summary: EventSummary { snapshot() }
    public init() {}
    public mutating func append(_ events: [TaskEvent]) {
        for event in events {
            switch event.kind {
            case .taskStarted(let started):
                if value.prompt == nil { value.prompt = started.prompt }
                if order.isEmpty { repoPath = started.repoPath ?? "" }
            case .toolCall(let call):
                value.activity.toolCalls += 1
                if call.category == "shell" { value.activity.commands += 1 }
                guard call.category == "edit" || call.category == "write" else { continue }
                value.activity.edits += 1
                guard let rawPath = call.path, !rawPath.isEmpty else { continue }
                let prefix = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
                let path = !repoPath.isEmpty && rawPath.hasPrefix(prefix) ? String(rawPath.dropFirst(prefix.count)) : rawPath
                if latest[path] == nil { order.append(path) }
                if let prior = latest[path] { pending[prior.0] = nil }
                latest[path] = (call.callID, .unconfirmed)
                sequences[path] = event.seq
                pending[call.callID] = path
            case .toolResult(let result):
                guard let path = pending.removeValue(forKey: result.callID), latest[path]?.0 == result.callID else { continue }
                latest[path] = (result.callID, result.ok ? .edited : .failed)
            default: break
            }
        }
        value.totalFiles = order.count
    }
    public func snapshot(fileLimit: Int = 100) -> EventSummary {
        var value = self.value
        let paths = order.prefix(fileLimit)
        value.files = paths.map { EditedFile(path: $0, status: latest[$0]?.1 ?? .unconfirmed) }
        value.fileSequences = Dictionary(uniqueKeysWithValues: paths.map { ($0, sequences[$0] ?? 0) })
        return value
    }
    public mutating func setAvailability(_ value: EventAvailability) { self.value.availability = value }
}
