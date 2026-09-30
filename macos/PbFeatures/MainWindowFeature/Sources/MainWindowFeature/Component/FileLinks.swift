//
//  FileLinks.swift
//  MainWindowFeature
//
//  Opening what an agent points at: a file-name pill, a tool row's path, or a link in its Markdown.
//  Agent text is untrusted, so only three things ever reach the system:
//  - http(s) and mailto links, unchanged;
//  - an existing document — absolute, `file://`, or relative to the task's repository, with an
//    editor-style line suffix (`:149`, `:149:3`, `#L149`) dropped first — in its default app;
//  - for anything that is not a known passive document (an executable, a script, an app or other
//    bundle, a web page…), only the nearest real folder around it — never a bundle, never the item.
//  Every other scheme, and any path that does not exist, is dropped.
//

import Foundation
import SwiftUI

// MARK: - FileLinks

enum FileLinks {

    /// What the file system says about a path; injectable so the rules are testable without disk.
    struct Probe: Sendable {
        let exists: @Sendable (String) -> Bool
        /// The path with every symlink resolved, so the checks below judge what would actually open.
        let resolved: @Sendable (String) -> String
        let isExecutable: @Sendable (String) -> Bool
        /// A bundle or package (an `.app`, a `.pkg`…): opening one launches or installs it.
        let isPackage: @Sendable (String) -> Bool
        let isDirectory: @Sendable (String) -> Bool

        nonisolated static let live = Probe(
            exists: { FileManager.default.fileExists(atPath: $0) },
            resolved: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            isExecutable: { path in
                let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isExecutableKey, .isDirectoryKey])
                return values?.isDirectory != true && values?.isExecutable == true
            },
            isPackage: { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true },
            isDirectory: { (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        )
    }

    /// Passive documents: opened in their default app. Anything else (scripts, apps, installers,
    /// web pages that run script, location files…) only ever reveals its folder. An allowlist, so a
    /// type nobody thought of fails safe.
    nonisolated static let documentExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rst", "log", "csv", "tsv", "json", "jsonl", "yml", "yaml", "toml", "ini",
        "cfg", "conf", "properties", "lock", "diff", "patch", "pdf", "png", "jpg", "jpeg", "gif", "heic", "tiff",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "java", "kt", "kts", "gradle", "py", "rb", "js",
        "jsx", "ts", "tsx", "css", "scss", "sql", "proto", "xcconfig", "strings", "stringsdict", "plist", "xml",
        "entitlements", "pbxproj", "gitignore", "editorconfig"
    ]

    nonisolated static let webSchemes: Set<String> = ["http", "https", "mailto"]

    /// The decision for one tapped link.
    enum Target: Equatable {
        /// Hand this URL to the system (a web link, a document, or a folder).
        case open(URL)
        /// Drop it.
        case discard
    }

    nonisolated static func target(for url: URL, repoPath: String?, probe: Probe = .live) -> Target {
        let scheme = url.scheme?.lowercased()
        if let scheme, webSchemes.contains(scheme) { return .open(url) }
        let rawPath: String = if scheme == "file" {
            url.path
        } else {
            // Scheme-less, or a "scheme" that is really a file name: `README.md:12` parses as
            // scheme "README.md". Either way the text is tried as a path, and nothing else opens.
            url.absoluteString.removingPercentEncoding ?? url.absoluteString
        }
        guard let file = fileURL(forPath: rawPath, repoPath: repoPath, fileExists: probe.exists) else { return .discard }
        let path = probe.resolved(file.path)
        if isPassiveDocument(path, probe: probe) { return .open(URL(fileURLWithPath: path)) }
        return safeFolder(containing: path, probe: probe).map { .open(URL(fileURLWithPath: $0, isDirectory: true)) } ?? .discard
    }

    nonisolated static func isPassiveDocument(_ path: String, probe: Probe) -> Bool {
        guard !probe.isDirectory(path), !probe.isExecutable(path), !probe.isPackage(path) else { return false }
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        // A plain file with no extension (LICENSE, Makefile, .env) opens as text.
        return ext.isEmpty || documentExtensions.contains(ext)
    }

    /// The nearest folder at or above `path` that is a real folder, never a bundle: a folder opens in
    /// Finder, a bundle would launch.
    nonisolated static func safeFolder(containing path: String, probe: Probe) -> String? {
        var current = probe.isDirectory(path) && !probe.isPackage(path) ? path : (path as NSString).deletingLastPathComponent
        while !current.isEmpty, current != "/" {
            let resolved = probe.resolved(current)
            if probe.isDirectory(resolved), !probe.isPackage(resolved) { return resolved }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// The file URL for a path string as an agent wrote it, or `nil` when it does not exist.
    nonisolated static func fileURL(
        forPath rawPath: String, repoPath: String?, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        let path = strippingLineSuffix(rawPath.trimmingCharacters(in: .whitespaces))
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else if let repoPath, !repoPath.isEmpty {
            absolute = ((repoPath as NSString).expandingTildeInPath as NSString).appendingPathComponent(expanded)
        } else {
            return nil
        }
        let standardized = (absolute as NSString).standardizingPath
        return fileExists(standardized) ? URL(fileURLWithPath: standardized) : nil
    }

    /// A link a pill or row can hand to `openURL`: scheme-less, so the task's `OpenURLAction`
    /// resolves it against the repository. A relative path gets a `./` prefix so a name like
    /// `README.md:12` can never parse as a URL scheme.
    nonisolated static func link(forPath path: String) -> URL? {
        let unambiguous = path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix(".") ? path : "./\(path)"
        guard let encoded = unambiguous.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: encoded)
    }

    /// Drops `:149`, `:149:3` and `#L149` / `#L149-L160` from the end of a path.
    nonisolated static func strippingLineSuffix(_ path: String) -> String {
        var result = path
        if let hash = result.range(of: "#L", options: .backwards), result[hash.upperBound...].allSatisfy({ $0.isNumber || $0 == "-" || $0 == "L" }) {
            result = String(result[..<hash.lowerBound])
        }
        for _ in 0 ..< 2 {
            guard let colon = result.lastIndex(of: ":") else { break }
            let tail = result[result.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { break }
            result = String(result[..<colon])
        }
        return result
    }
}

// MARK: - Opening links

extension View {
    /// Routes every `openURL` below — Markdown links and tapped paths — through `FileLinks`, so a
    /// path opens in its default app and a web link in the browser.
    func opensFileLinks(repoPath: String?) -> some View {
        environment(\.openURL, OpenURLAction { url in
            switch FileLinks.target(for: url, repoPath: repoPath) {
            case .open(let target): .systemAction(target)
            case .discard: .discarded
            }
        })
    }
}
