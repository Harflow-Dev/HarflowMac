import Foundation

/// A byte cursor is scoped to the file identity and its consumed boundary bytes.
public struct EventPageCursor: Equatable, Sendable {
    public let fileID: UInt64
    public let offset: UInt64
    public let anchor: Data
    public let snapshotEnd: UInt64
    public let snapshotHead: Data
    public let snapshotTail: Data
    public init(fileID: UInt64, offset: UInt64, anchor: Data, snapshotEnd: UInt64? = nil,
                snapshotHead: Data = Data(), snapshotTail: Data = Data()) {
        self.fileID = fileID
        self.offset = offset
        self.anchor = anchor
        self.snapshotEnd = snapshotEnd ?? offset
        self.snapshotHead = snapshotHead
        self.snapshotTail = snapshotTail
    }
}

public struct EventPage: Sendable {
    public let events: [TaskEvent]
    public let next: EventPageCursor?
    public let end: EventPageCursor
    public let bytesRead: Int
}

public enum EventPageError: Error { case unavailable, changed }

public enum EventPages {
    public static let pageSize = 100
    public static let byteLimit = 1 << 20

    /// Reads backward at most one byte budget; only complete newline-terminated records count.
    public static func read(path: String, before cursor: EventPageCursor? = nil,
                            limit: Int = pageSize, byteLimit: Int = byteLimit) throws -> EventPage {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw EventPageError.unavailable }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw EventPageError.unavailable }
        let fileID = UInt64(info.st_ino)
        let size = UInt64(max(0, info.st_size))
        var bytesRead = 0
        func readAnchor(at offset: UInt64) throws -> Data {
            let data = try anchor(handle, at: offset)
            bytesRead += data.count
            return data
        }
        let snapshotEnd = cursor?.snapshotEnd ?? size
        let headOffset = min(snapshotEnd, 64)
        let head = try readAnchor(at: headOffset)
        let snapshotTail = try readAnchor(at: snapshotEnd)
        if let cursor {
            guard cursor.fileID == fileID, size >= snapshotEnd, cursor.offset <= size,
                  head == cursor.snapshotHead, snapshotTail == cursor.snapshotTail,
                  try readAnchor(at: cursor.offset) == cursor.anchor else { throw EventPageError.changed }
        }
        let boundary = cursor?.offset ?? size
        let start = boundary > UInt64(byteLimit) ? boundary - UInt64(byteLimit) : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(boundary - start)) ?? Data()
        bytesRead += data.count
        guard data.count == Int(boundary - start) else { throw EventPageError.changed }
        let decoded = decode(data, start: start, boundary: boundary, initial: cursor == nil, limit: limit)
        let nextOffset = decoded.nextOffset
        let endOffset = decoded.endOffset
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0, UInt64(max(0, after.st_size)) >= snapshotEnd,
              try readAnchor(at: headOffset) == head,
              try readAnchor(at: snapshotEnd) == snapshotTail else { throw EventPageError.changed }
        let next = nextOffset == 0 ? nil : EventPageCursor(
            fileID: fileID, offset: nextOffset, anchor: try readAnchor(at: nextOffset),
            snapshotEnd: snapshotEnd, snapshotHead: head, snapshotTail: snapshotTail
        )
        let end = EventPageCursor(fileID: fileID, offset: endOffset, anchor: try readAnchor(at: endOffset),
                                  snapshotEnd: snapshotEnd, snapshotHead: head, snapshotTail: snapshotTail)
        return EventPage(events: decoded.events, next: next, end: end, bytesRead: bytesRead)

    }

    private static func decode(_ data: Data, start: UInt64, boundary: UInt64, initial: Bool,
                               limit: Int) -> (events: [TaskEvent], nextOffset: UInt64, endOffset: UInt64) {
        let newlines = data.indices.filter { data[$0] == 10 }
        var records: [(Int, TaskEvent)] = []
        var examined = 0
        let countLimit = max(1, min(limit, pageSize))
        var endOffset = boundary
        // Initial tail excludes an incomplete final record; subsequent cursors are line starts.
        if initial { endOffset = newlines.last.map { start + UInt64($0 + 1) } ?? start }
        var right = Int(endOffset - start)
        for (index, newline) in newlines.enumerated().reversed() where newline < right {
            let lineStart = index == 0 ? 0 : newlines[index - 1] + 1
            if lineStart == 0 && start > 0 { break }
            examined += 1
            if let line = String(bytes: data[lineStart..<newline], encoding: .utf8), let event = TaskEvent(line: line) {
                records.append((lineStart, event))
            }
            right = lineStart
            if examined == countLimit { break }
        }
        // A byte-limited page may contain fewer events. Advance past its partial leading record.
        let nextOffset: UInt64
        if examined >= countLimit {
            nextOffset = start + UInt64(right)
        } else {
            nextOffset = start == 0 || records.isEmpty ? start : start + UInt64(newlines.first.map { $0 + 1 } ?? 0)
        }
        return (records.reversed().map(\.1), nextOffset, endOffset)
    }

    private static func anchor(_ handle: FileHandle, at offset: UInt64) throws -> Data {
        let count = Int(min(offset, 64))
        try handle.seek(toOffset: offset - UInt64(count))
        return try handle.read(upToCount: count) ?? Data()
    }
}

public struct EventHistoryState: Equatable, Sendable {
    public var hasMore: Bool
    public var isLoading: Bool
    public var error: String?
    public var generation: Int
    public init(hasMore: Bool = false, isLoading: Bool = false, error: String? = nil, generation: Int = 0) {
        self.hasMore = hasMore
        self.isLoading = isLoading
        self.error = error
        self.generation = generation
    }
}
