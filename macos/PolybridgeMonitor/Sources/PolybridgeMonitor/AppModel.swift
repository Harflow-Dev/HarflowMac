import AppKit
import Combine
import MonitorCore
import SwiftUI
@preconcurrency import UserNotifications

enum Selection: Hashable {
    case task(String)
    case group(String)
    case interactive(UUID)
}

/// Everything the window and the menu bar show. Reads come from `polybridge-ctl list/status` and,
/// for live timelines, each task's own `events.jsonl`; every action goes through `polybridge-ctl`
/// or `polybridge-setup`. The app never writes polybridge's state.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Settings (UserDefaults-backed).
    @AppStorage("toolDirectory") var toolDirectory: String = ""
    @AppStorage("openWindowOnStart") var openWindowOnStart = true
    @AppStorage("notifyOnFinish") var notifyOnFinish = true

    @Published private(set) var tasks: [TaskInfo] = []
    @Published private(set) var listError: ToolError?
    @Published private(set) var hasListed = false
    @Published private(set) var titles: [String: String] = [:]
    @Published var selection: Selection?
    @Published private(set) var snapshots: [String: TaskInfo] = [:]
    @Published private(set) var sessions: [TerminalSession] = []
    /// Last outcome per task for the header (a refusal, "queued", …).
    @Published var messages: [String: String] = [:]
    @Published var busy: Set<String> = []
    @Published var showNewSession = false

    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    var tasksDirectory: String { TaskTitle.tasksDirectory(home: home) }

    private var loginPath: String?
    private var uvToolBin: String?
    private var watcher: DirectoryWatcher?
    private var pendingRefresh: DispatchWorkItem?
    private var pollTimer: Timer?
    private var eventStores: [String: EventStore] = [:]
    private var refreshing = false
    private var refreshAgain = false
    private var lastRefresh = Date.distantPast
    var openWindowAction: (() -> Void)?

    private init() {}

    // MARK: Startup

    func start() {
        Task {
            await discoverEnvironment()
            await refresh()
            startWatching()
        }
    }

    private func discoverEnvironment() async {
        let runner = ProcessRunner()
        let base = ProcessInfo.processInfo.environment
        if case .success(let output) = await runner.run(executable: LaunchEnvironment.loginPathArgv[0], arguments: Array(LaunchEnvironment.loginPathArgv.dropFirst()), environment: LaunchEnvironment.build(base: base, loginPath: nil, toolDirectory: nil), currentDirectory: home, timeout: 8) {
            loginPath = LaunchEnvironment.parseLoginPath(output.stdout)
        }
        for uv in ToolLocator.uvCandidates(home: home) where FileManager.default.isExecutableFile(atPath: uv) {
            if case .success(let output) = await runner.run(executable: uv, arguments: ["tool", "dir", "--bin"], environment: environment(), currentDirectory: nil, timeout: 8), output.exitCode == 0 {
                uvToolBin = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
    }

    var locator: ToolLocator {
        ToolLocator(overrideDirectory: toolDirectory.isEmpty ? nil : toolDirectory, home: home, uvToolBin: uvToolBin)
    }

    func environment(toolDirectory: String? = nil) -> [String: String] {
        LaunchEnvironment.build(base: ProcessInfo.processInfo.environment, loginPath: loginPath, toolDirectory: toolDirectory)
    }

    func ctl() -> Result<CtlClient, ToolError> {
        locator.locate("polybridge-ctl").map { path in
            CtlClient(executable: path, environment: environment(toolDirectory: (path as NSString).deletingLastPathComponent))
        }
    }

    func setup() -> Result<SetupClient, ToolError> {
        locator.locate("polybridge-setup").map { path in
            SetupClient(executable: path, environment: environment(toolDirectory: (path as NSString).deletingLastPathComponent))
        }
    }

    func settingsChanged() {
        Task { await refresh() }
    }

    // MARK: Refresh

    private func startWatching() {
        let watcher = DirectoryWatcher(path: tasksDirectory) { [weak self] names in
            guard names.contains(where: RefreshTrigger.isRelevant) else { return }
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watcher.start()
        self.watcher = watcher
        // A dead owner writes nothing, and the tasks folder may not exist yet: a 10 s safety poll
        // while that matters, and an unconditional reconcile every minute regardless.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let due = Date().timeIntervalSince(self.lastRefresh) >= RefreshTrigger.reconcileInterval
                if due || self.tasks.contains(where: { $0.status.isRunning }) || self.listError != nil || !self.watcherActive {
                    await self.refresh()
                }
            }
        }
    }

    private var watcherActive: Bool { watcher?.isActive ?? false }

    /// FSEvents fire in bursts while a task writes its record; one list per second is plenty.
    func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.pendingRefresh = nil
                await self?.refresh()
            }
        }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            let result: Result<[TaskInfo], ToolError>
            switch ctl() {
            case .failure(let error): result = .failure(error)
            case .success(let client): result = await client.list()
            }
            switch result {
            case .success(let listed):
                let previous = tasks
                tasks = listed
                listError = nil
                lastRefresh = Date()
                // A task that left the listing (retention) must not live on in the detail cache.
                let listedIDs = Set(listed.map(\.taskID))
                snapshots = snapshots.filter { listedIDs.contains($0.key) }
                if hasListed { notifyFinished(Lineage.finishedRoots(previous: previous, current: listed)) }
                hasListed = true
                loadTitles()
                for id in eventStores.keys { await refreshSnapshot(id) }
            case .failure(let error):
                listError = error
            }
        } while refreshAgain
        if !watcherActive { watcher?.start() }
    }

    private func loadTitles() {
        let missing = tasks.map(\.taskID).filter { titles[$0] == nil }
        guard !missing.isEmpty else { return }
        let dir = tasksDirectory
        Task.detached(priority: .utility) {
            var found: [String: String] = [:]
            for id in missing.prefix(500) {
                guard let path = TaskTitle.eventsPath(tasksDirectory: dir, taskID: id),
                      let prompt = TaskTitle.firstPrompt(eventsPath: path), let title = TaskTitle.from(prompt: prompt) else { continue }
                found[id] = title
            }
            let result = found
            await MainActor.run { self.titles.merge(result) { old, _ in old } }
        }
    }

    func title(_ taskID: String) -> String {
        titles[taskID] ?? "Task \(taskID.prefix(8))"
    }

    /// Every running task in the subtrees of `ids` (members of a group, say), the tasks included.
    func runningInSubtrees(of ids: [String]) -> [String] {
        var result: [String] = []
        var frontier = ids
        var seen = Set<String>()
        while let id = frontier.popLast() {
            guard seen.insert(id).inserted else { continue }
            if task(id)?.status.isRunning == true { result.append(id) }
            frontier.append(contentsOf: Lineage.children(of: id, in: tasks).map(\.taskID))
        }
        return result
    }

    func task(_ id: String) -> TaskInfo? {
        tasks.first { $0.taskID == id }
    }

    /// The fullest view of a task: its snapshot if fetched, else its listing entry.
    func detail(_ id: String) -> TaskInfo? {
        if hasListed, task(id) == nil { return nil }
        if let snapshot = snapshots[id], let listed = task(id), listed.status != snapshot.status {
            return listed
        }
        return snapshots[id] ?? task(id)
    }

    func refreshSnapshot(_ id: String) async {
        guard case .success(let client) = ctl() else { return }
        switch await client.status(id) {
        case .success(let info):
            snapshots[id] = info
        case .failure(let error):
            if error.refusalCode == "unknown_task" { snapshots[id] = nil }
        }
    }

    // MARK: Live events (ref-counted, only for what is on screen)

    func acquireEvents(_ taskID: String) -> EventStore {
        if let store = eventStores[taskID] {
            store.retainCount += 1
            return store
        }
        let path = TaskTitle.eventsPath(tasksDirectory: tasksDirectory, taskID: taskID) ?? "/dev/null"
        let store = EventStore(taskID: taskID, path: path)
        store.retainCount = 1
        eventStores[taskID] = store
        store.start()
        Task { await refreshSnapshot(taskID) }
        return store
    }

    func releaseEvents(_ taskID: String) {
        guard let store = eventStores[taskID] else { return }
        store.retainCount -= 1
        if store.retainCount <= 0 {
            store.stop()
            eventStores[taskID] = nil
        }
    }

    func eventStore(_ taskID: String) -> EventStore? { eventStores[taskID] }

    // MARK: Actions (all through polybridge-ctl)

    private func perform(_ taskID: String, _ work: @escaping (CtlClient) async -> String?) {
        guard !busy.contains(taskID) else { return }
        switch ctl() {
        case .failure(let error):
            messages[taskID] = error.message
        case .success(let client):
            busy.insert(taskID)
            Task {
                let message = await work(client)
                busy.remove(taskID)
                messages[taskID] = message
                await refresh()
                await refreshSnapshot(taskID)
            }
        }
    }

    func cancel(_ taskID: String) {
        perform(taskID) { client in
            switch await client.cancel(taskID) {
            case .success(let result): return CascadeSummary.describe(result)
            case .failure(let error): return error.message
            }
        }
    }

    func cancelAll(_ ids: [String]) {
        for id in ids { cancel(id) }
    }

    func send(_ taskID: String, text: String) {
        perform(taskID) { client in
            switch await client.send(taskID, text: text) {
            case .success: return "Queued — not yet delivered. The timeline shows it once the agent receives it."
            case .failure(let error): return error.message
            }
        }
    }

    func resume(_ taskID: String, text: String) {
        perform(taskID) { [weak self] client in
            switch await client.resume(taskID, text: text) {
            case .success(let newID):
                await MainActor.run { self?.selection = .task(newID) }
                return "Continued as task \(newID.prefix(8))."
            case .failure(let error): return error.message
            }
        }
    }

    func startHeadless(_ request: RunRequest, completion: @escaping (String?) -> Void) {
        switch ctl() {
        case .failure(let error): completion(error.message)
        case .success(let client):
            Task {
                switch await client.run(request) {
                case .success(let id):
                    await refresh()
                    selection = .task(id)
                    completion(nil)
                case .failure(let error):
                    completion(error.message)
                }
            }
        }
    }

    // MARK: Take over

    enum Destination { case embedded, terminalApp }

    func takeover(_ taskID: String, to destination: Destination) {
        guard !busy.contains(taskID) else { return }
        let ctlResult = ctl()
        guard case .success(let client) = ctlResult else {
            if case .failure(let error) = ctlResult { messages[taskID] = error.message }
            return
        }
        busy.insert(taskID)
        messages[taskID] = "Stopping the headless run and reserving the session…"
        Task {
            defer { busy.remove(taskID) }
            switch await client.takeover(taskID) {
            case .failure(let error):
                messages[taskID] = error.message
            case .success(let grant):
                switch destination {
                case .embedded: openEmbedded(taskID: taskID, grant: grant, client: client)
                case .terminalApp: await openInTerminalApp(taskID: taskID, grant: grant, client: client)
                }
            }
            await refresh()
            await refreshSnapshot(taskID)
        }
    }

    private func openEmbedded(taskID: String, grant: TakeoverGrant, client: CtlClient) {
        let command: TerminalCommand
        do {
            command = try TakeoverWrapper.command(argv: grant.argv, cwd: grant.cwd, environment: environment())
        } catch {
            messages[taskID] = "The takeover command could not be started: \(error)"
            return
        }
        let session = TerminalSession(kind: .takeover(taskID: taskID), title: title(taskID), backend: task(taskID)?.backend ?? "", command: command)
        session.onStarted = { [weak self, weak session] pid in
            Task { @MainActor in
                guard let self, let session else { return }
                switch await client.takeoverAttach(taskID, pid: pid) {
                case .success:
                    session.attached = true
                    self.messages[taskID] = nil
                case .failure(let error):
                    // Without the attach the session is not reserved, so a resume elsewhere could
                    // write the same conversation. End the terminal rather than risk two writers,
                    // and say it closed only once its exit is confirmed.
                    session.attachError = error.message
                    self.messages[taskID] = "The takeover could not be attached (\(error.message)); ending the terminal…"
                    session.terminate { [weak self] outcome in
                        switch outcome {
                        case .stopped, .alreadyGone:
                            self?.messages[taskID] = "The terminal was closed because the takeover could not be attached: \(error.message)"
                        case .survived(let pids):
                            self?.messages[taskID] = "The takeover could not be attached and these processes would not exit — end them yourself: \(pids.map(String.init).joined(separator: ", ")). \(error.message)"
                        }
                    }
                }
            }
        }
        sessions.append(session)
        session.start()
    }

    private func openInTerminalApp(taskID: String, grant: TakeoverGrant, client: CtlClient) async {
        do {
            let files = try TerminalAppHandoff.files(ctl: client.executable, taskID: taskID, grant: grant)
            let parent = FileManager.default.temporaryDirectory.appendingPathComponent("PolybridgeMonitor", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = try TerminalAppHandoff.write(files, under: parent)
            let result = await ProcessRunner().run(executable: "/usr/bin/open", arguments: ["-a", "Terminal", script.path], environment: environment(), currentDirectory: nil, timeout: 15)
            if case .success(let output) = result, output.exitCode == 0 {
                messages[taskID] = "Opened in Terminal.app. It attaches itself before starting; if it cannot, it refuses to start the session."
            } else {
                messages[taskID] = "Terminal.app could not be opened. The takeover lapses unattached in 120 s."
            }
        } catch {
            messages[taskID] = "The Terminal.app hand-off could not be written: \(error.localizedDescription)"
        }
    }

    func session(forTask taskID: String) -> TerminalSession? {
        sessions.last { if case .takeover(let id) = $0.kind { return id == taskID } else { return false } }
    }

    // MARK: New interactive session

    func startInteractive(backend: String, repo: String) -> String? {
        do {
            let command = try InteractiveSession.command(backend: backend, repo: repo, environment: environment())
            let session = TerminalSession(kind: .interactive, title: "\(backend) · \(Format.repo(repo))", backend: backend, command: command)
            session.onEnded = { [weak self, weak session] in
                Task { @MainActor in
                    guard let self, let session else { return }
                    if self.selection != .interactive(session.id) { self.sessions.removeAll { $0 === session } }
                }
            }
            sessions.append(session)
            session.start()
            selection = .interactive(session.id)
            return nil
        } catch {
            return "Could not start \(backend): \(error)"
        }
    }

    func removeSession(_ session: TerminalSession) {
        session.terminate()
        sessions.removeAll { $0 === session }
    }

    var interactiveSessions: [TerminalSession] {
        sessions.filter { if case .interactive = $0.kind { return !$0.ended } else { return false } }
    }

    // MARK: URL + notifications

    func handle(url: URL) {
        guard let id = MonitorURL.taskID(from: url) else { return }
        selection = .task(id)
        Task { await refresh() }
        if openWindowOnStart { showWindow() }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindowAction?()
    }

    /// Notifications need a real bundle (a bare `swift run` binary has none).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    private func notifyFinished(_ finished: [TaskInfo]) {
        guard notifyOnFinish, canNotify, !finished.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                for task in finished {
                    let content = UNMutableNotificationContent()
                    content.title = "\(task.status.label): \(self.title(task.taskID))"
                    content.body = "\(task.backend) · \(Format.repo(task.repoPath))"
                    content.userInfo = ["task_id": task.taskID]
                    try? await center.add(UNNotificationRequest(identifier: "finished-\(task.taskID)", content: content, trigger: nil))
                }
            }
        }
    }

    var runningCount: Int { tasks.filter { $0.status.isRunning }.count }

    var connectionLine: String {
        if let listError {
            if case .notFound = listError { return "polybridge-ctl not found" }
            return "polybridge not readable"
        }
        let backends = Set(tasks.map(\.backend)).sorted()
        return hasListed ? "polybridge connected" + (backends.isEmpty ? "" : " · " + backends.joined(separator: ", ")) : "connecting…"
    }
}

/// One task's decoded events, tailed live while something on screen holds it.
@MainActor
final class EventStore: ObservableObject {
    let taskID: String
    let path: String
    @Published private(set) var events: [TaskEvent] = []
    @Published private(set) var items: [TimelineItem] = []
    var retainCount = 0
    private var tailer: EventFileTailer?

    init(taskID: String, path: String) {
        self.taskID = taskID
        self.path = path
    }

    func start() {
        let tailer = EventFileTailer(path: path) { [weak self] events, reset in
            MainActor.assumeIsolated {
                guard let self else { return }
                if reset { self.events = [] }
                // Unknown kinds are kept for Raw events but never shown on the timeline.
                self.events.append(contentsOf: events)
                self.items = Timeline.items(from: self.events)
            }
        }
        tailer.start()
        self.tailer = tailer
    }

    func stop() {
        tailer?.stop()
        tailer = nil
    }

    var current: TimelineItem? { Timeline.current(in: items) }
    var activity: ActivityCounts { Timeline.activity(from: events) }
    var prompt: String? { Timeline.prompt(in: events) }
}

/// FSEvents on the tasks folder; reports the changed file names.
final class DirectoryWatcher {
    private let path: String
    private let handler: ([String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.polybridge.monitor.fsevents")

    init(path: String, handler: @escaping ([String]) -> Void) {
        self.path = path
        self.handler = handler
    }

    var isActive: Bool { stream != nil }

    func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: path) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let names = (0..<count).compactMap { (array[$0] as? String).map { ($0 as NSString).lastPathComponent } }
            watcher.handler(names)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
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
