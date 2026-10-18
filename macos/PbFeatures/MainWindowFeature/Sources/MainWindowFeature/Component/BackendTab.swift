//
//  BackendTab.swift
//  MainWindowFeature
//
//  Shared between the Sidebar's backend filter row and New Session's Agent picker (Monitor piece
//  6) — both present the same catalog, just as "All" + tabs vs. a plain picker. A Component Model
//  per the root AGENTS.md's decision 9: mapping from `PbRepository.BackendCatalog` to this happens
//  in the VM, never in a UseCase.
//

import Foundation

/// One backend option: a Sidebar tab or a New Session Agent choice. `isNotFound` is `true` only when
/// polybridge positively confirmed the backend's binary isn't on PATH — never for "All", never for a
/// backend merely absent from a degraded catalog, and never for a backend known only from task
/// history (its tasks ran, so it plainly exists).
struct BackendTab: Identifiable, Equatable, Sendable {
    let id: String
    let isNotFound: Bool

    /// The Sidebar's "All" tab — never dimmed, never not-found.
    static let all = BackendTab(id: "all", isNotFound: false)
}
