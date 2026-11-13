import Foundation

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
