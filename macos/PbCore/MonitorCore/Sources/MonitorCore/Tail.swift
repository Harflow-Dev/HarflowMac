import Foundation

/// Byte-offset tail over an append-only JSONL file. Pure bookkeeping, so it is testable without
/// a file: feed it what is on disk now and it returns the complete lines it has not returned yet.
///
/// The offset only ever advances past a newline, so a line the writer is half-way through is read
/// again, whole, next time. A file that shrank, was replaced (another inode), or was truncated and
/// rewritten in place to at least its old size (the bytes just before the offset no longer match
/// what was consumed there) restarts from 0 and says so, so the caller can drop what it had.
public struct LineTail: Equatable, Sendable {
    public private(set) var offset: UInt64 = 0
    public private(set) var fileID: UInt64?
    /// The last consumed bytes (up to `anchorLength`, ending at `offset`): a same-inode rewrite
    /// that regrows past the offset changes them. Event lines carry a seq and a timestamp, so a
    /// rewrite that reproduces these bytes exactly is not a practical concern.
    public private(set) var anchor = Data()
    public static let anchorLength = 64
    /// Bound on one read, so a huge backlog is consumed over several passes instead of at once.
    public var maxChunk: Int
    public var maxLines: Int = .max

    public init(maxChunk: Int = 4 << 20) {
        self.maxChunk = maxChunk
    }

    public struct Step: Equatable, Sendable {
        public var lines: [String]
        public var reset: Bool
        /// True when the read stopped at `maxChunk` and more is waiting.
        public var more: Bool
    }

    /// Decide where to read from, given the file's current size and identity. Returns the offset
    /// to read at and whether the tail restarted.
    /// `bytesBeforeOffset` is what is on disk now in the `anchor.count` bytes ending at `offset`
    /// (nil if not read); a mismatch with `anchor` is a rewrite.
    public mutating func prepare(size: UInt64, fileID: UInt64?, bytesBeforeOffset: Data? = nil) -> (readFrom: UInt64, reset: Bool) {
        var reset = false
        if let known = self.fileID, let fileID, known != fileID {
            reset = true
        } else if size < offset {
            reset = true
        } else if let bytesBeforeOffset, !anchor.isEmpty, bytesBeforeOffset != anchor {
            reset = true
        }
        if reset {
            offset = 0
            anchor = Data()
        }
        self.fileID = fileID
        return (offset, reset)
    }

    /// Consume `data`, which was read starting at the offset `prepare` returned.
    public mutating func consume(_ data: Data, reset: Bool) -> Step {
        let endings = data.indices.filter { data[$0] == 10 }
        guard let lastNewline = endings.prefix(maxLines).last else {
            // No complete line yet. If a single line is longer than a whole chunk, skip it rather
            // than wedge on it forever.
            if data.count >= maxChunk {
                offset += UInt64(data.count)
                remember(data)
                return Step(lines: [], reset: reset, more: true)
            }
            return Step(lines: [], reset: reset, more: false)
        }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        remember(complete)
        let lines = complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map {
            String(decoding: $0, as: UTF8.self)
        }
        return Step(lines: lines, reset: reset, more: data.count >= maxChunk || endings.count > maxLines)
    }

    public mutating func seed(_ cursor: EventPageCursor) {
        offset = cursor.offset
        fileID = cursor.fileID
        anchor = cursor.anchor
    }

    private mutating func remember<D: DataProtocol>(_ consumed: D) {
        var combined = anchor
        combined.append(contentsOf: consumed.suffix(Self.anchorLength))
        anchor = Data(combined.suffix(Self.anchorLength))
    }

    /// One pass over a file on disk. nil if the file cannot be opened (not created yet, or gone).
    public mutating func read(path: String) -> Step? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        var before: Data?
        if !anchor.isEmpty, offset >= UInt64(anchor.count), UInt64(info.st_size) >= offset {
            try? handle.seek(toOffset: offset - UInt64(anchor.count))
            before = try? handle.read(upToCount: anchor.count)
        }
        let (from, reset) = prepare(size: UInt64(info.st_size), fileID: UInt64(info.st_ino), bytesBeforeOffset: before)
        do {
            try handle.seek(toOffset: from)
            let data = try handle.read(upToCount: maxChunk) ?? Data()
            return consume(data, reset: reset)
        } catch {
            return nil
        }
    }
}

/// Whether a task's event log could actually be read the last time it was tailed — so an empty
/// event list never has to stand for both "nothing has happened yet" and "there is no log to read
/// at all". `.loading` until the first attempt settles one way or the other; a file that exists and
/// opens (even empty, even `/dev/null`) is `.available`, one that cannot be opened at all — missing,
/// or unreadable — is `.unavailable`.
public enum EventAvailability: Equatable, Sendable {
    case loading, available, unavailable
}

/// Watches one task's `events.jsonl`: a `DispatchSource` on the file descriptor wakes it on writes,
/// and a 1 s poll covers the times there is no descriptor to watch (the file does not exist yet, or
/// was replaced). Delivers decoded v1 events on the main queue; lines that are not v1 events are
/// skipped, unknown kinds are delivered as `.unknown` for the caller to ignore.
public final class EventFileTailer {
    public typealias Handler = (_ events: [TaskEvent], _ reset: Bool, _ availability: EventAvailability) -> Void

    public let path: String
    private let queue = DispatchQueue(label: "dev.polybridge.monitor.tail")
    private var tail = LineTail(maxChunk: EventPages.byteLimit)
    private var seeded = false
    private var olderCursor: EventPageCursor?
    private var history = EventHistoryState(isLoading: true)
    private var historyHandler: ((EventHistoryState) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var poll: DispatchSourceTimer?
    private var handler: Handler?
    private var stopped = false
    /// The last availability reported to `handler` — read only on `queue`, so a same-state drain
    /// never re-notifies the caller.
    private var availability: EventAvailability = .loading

    public init(path: String, historyHandler: ((EventHistoryState) -> Void)? = nil, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
        self.historyHandler = historyHandler
        tail.maxLines = EventPages.pageSize
    }

    public func start() {
        queue.async { [self] in
            startPoll()
            attachSource()
            drain()
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            source?.cancel()
            source = nil
            poll?.cancel()
            poll = nil
            handler = nil
        }
    }

    public func loadMore() {
        queue.async { [self] in
            guard !stopped else { return }
            guard !history.isLoading, let cursor = olderCursor else {
                publishHistory()
                return
            }
            history.isLoading = true
            publishHistory()
            do {
                let page = try EventPages.read(path: path, before: cursor)
                guard page.next != cursor else {
                    history.isLoading = false
                    history.error = "The older activity page made no progress."
                    publishHistory()
                    return
                }
                olderCursor = page.next
                history = EventHistoryState(hasMore: page.next != nil, generation: history.generation)
                if let handler {
                    DispatchQueue.main.async { handler(page.events, false, .available) }
                }
            } catch EventPageError.changed {
                seeded = false
                seed(reset: true)
                return
            } catch {
                history.isLoading = false
                history.error = "The older activity page could not be read."
            }
            publishHistory()
        }
    }

    private func publishHistory() {
        let value = history
        if let historyHandler { DispatchQueue.main.async { historyHandler(value) } }
    }

    private func seed(reset: Bool) {
        do {
            let page = try EventPages.read(path: path)
            tail.seed(page.end)
            seeded = true
            olderCursor = page.next
            history = EventHistoryState(hasMore: page.next != nil, generation: history.generation + (reset ? 1 : 0))
            availability = .available
            if let handler { DispatchQueue.main.async { handler(page.events, true, .available) } }
        } catch {
            history.isLoading = false
            history.error = "The activity log could not be read."
            if let handler { DispatchQueue.main.async { handler([], reset, .unavailable) } }
        }
        publishHistory()
    }

    private func startPoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if self.source == nil { self.attachSource() }
            self.drain()
        }
        timer.resume()
        poll = timer
    }

    private func attachSource() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let mask = source.data
            self.drain()
            if !mask.intersection([.delete, .rename, .revoke]).isEmpty {
                // The path now names something else (or nothing); watch it afresh on the next poll.
                source.cancel()
                if self.source === source { self.source = nil }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func drain() {
        guard !stopped else { return }
        if !seeded { seed(reset: false); return }
        var collected: [TaskEvent] = []
        var reset = false
        var opened = false
        // Bounded: a few chunks per wake-up, the poll picks up the rest.
        for _ in 0..<1 {
            guard let step = tail.read(path: path) else { break }
            opened = true
            if step.reset {
                seeded = false
                seed(reset: true)
                return
            }
            collected.append(contentsOf: step.lines.compactMap(TaskEvent.init(line:)))
            if !step.more { break }
        }
        // `tail.read` returns nil for a file that cannot be opened at all (missing, or unreadable) —
        // never for one that opened but was merely empty, which still counts as available.
        let nextAvailability: EventAvailability = opened ? .available : .unavailable
        let availabilityChanged = nextAvailability != availability
        availability = nextAvailability
        guard reset || !collected.isEmpty || availabilityChanged, let handler else { return }
        let reportedAvailability = availability
        DispatchQueue.main.async { handler(collected, reset, reportedAvailability) }
    }
}
