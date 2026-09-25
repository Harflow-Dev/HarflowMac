import CoreServices
import Foundation

// MARK: - DirectoryWatcher

/// FSEvents on the tasks folder; reports the changed file names. Ported from `AppModel.swift:527-564`
/// (F4-28) into Swift 6 mode with a `@Sendable` handler, per decision 12. Starts only if the folder
/// exists (the tasks directory may not exist yet at launch); 0.3 s latency, `.fileEvents`/`.noDefer`,
/// since-now. `self` is passed unretained into the FSEvents context, so it must outlive its stream —
/// `deinit` tears the stream down before `self` goes away.
public final class DirectoryWatcher: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.polybridge.monitor.fsevents")

    public init(path: String, handler: @escaping @Sendable ([String]) -> Void) {
        self.path = path
        self.handler = handler
    }

    public var isActive: Bool { stream != nil }

    public func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: path) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let names = (0 ..< count).compactMap { (array[$0] as? String).map { ($0 as NSString).lastPathComponent } }
            watcher.handler(names)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
