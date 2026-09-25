import Foundation

/// A task's display title. Listings carry no prompt, so the title comes from the first line of
/// the task's own `events.jsonl` (`task_started.prompt`), read-only.
public enum TaskTitle {
    public static let maxLength = 90

    public static func from(prompt: String) -> String? {
        for line in prompt.split(whereSeparator: \.isNewline) {
            var text = line.trimmingCharacters(in: .whitespaces)
            while text.hasPrefix("#") { text.removeFirst() }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
        }
        return nil
    }

    /// The prompt from the first line of an events log, reading at most `limit` bytes.
    public static func firstPrompt(eventsPath: String, limit: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: eventsPath) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        guard let event = TaskEvent(line: String(decoding: data[data.startIndex..<newline], as: UTF8.self)),
              case .taskStarted(let started) = event.kind else { return nil }
        return started.prompt
    }

    /// `<home>/.polybridge/tasks`, as `tasks.default_log_dir()` computes it from `$HOME`.
    public static func tasksDirectory(home: String) -> String {
        (home as NSString).appendingPathComponent(".polybridge/tasks")
    }

    public static func eventsPath(tasksDirectory: String, taskID: String) -> String? {
        guard MonitorURL.isValidTaskID(taskID) else { return nil }
        return (tasksDirectory as NSString).appendingPathComponent("\(taskID).events.jsonl")
    }
}

extension LaunchEnvironment {
    /// The PATH printed by `loginPathArgv`. A login file that prints something ends up before it,
    /// so only the last line counts, and it must look like a PATH.
    public static func parseLoginPath(_ stdout: Data) -> String? {
        let text = String(decoding: stdout, as: UTF8.self)
        guard let last = text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces),
              last.hasPrefix("/"), !last.contains("\u{0}") else { return nil }
        return last
    }
}
