import Foundation
import Mockable
import SwiftEnvironment

// MARK: - FilePreviewResult

/// The untracked-file preview read's three outcomes (`TimelineViews.swift:350-356`).
public enum FilePreviewResult: Equatable, Sendable {
    case unreadable
    case binary
    case text(String)
}

// MARK: - FilePreviewRepository

/// The untracked-file preview read, moved behind a use case per decision 9: at most 64 KiB,
/// distinguishing unreadable, binary (a NUL byte), and text.
@Mockable
public protocol FilePreviewRepository: Sendable {
    func preview(repo: String, path: String) async -> FilePreviewResult
}

// MARK: - FilePreviewRepositoryImpl

public struct FilePreviewRepositoryImpl: FilePreviewRepository {
    public static let maxBytes = 64 * 1024

    public init() {}

    public func preview(repo: String, path: String) async -> FilePreviewResult {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unreadable }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Self.maxBytes)) ?? Data()
        if data.contains(0) { return .binary }
        // Arbitrary file bytes may not be valid UTF8; a failable conversion here must not crash the
        // preview, so the never-failing initializer is intentional.
        // swiftlint:disable:next optional_data_string_conversion
        return .text(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - NullFilePreviewRepository

public struct NullFilePreviewRepository: FilePreviewRepository {
    public init() {}
    public func preview(repo _: String, path _: String) async -> FilePreviewResult { .unreadable }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global file-preview repository.
    @GlobalEntry var filePreviewRepository: any FilePreviewRepository = NullFilePreviewRepository()
}
