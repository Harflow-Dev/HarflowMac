//
//  RecentRepos.swift
//  MainWindowFeature
//

import HfUI
import SwiftUI

// MARK: - RecentRepoModel

/// One "Recent" chip: a repository the user has already run a task in.
struct RecentRepoModel: Identifiable, Equatable {
    let path: String
    /// The last path component, shown on the chip.
    let name: String
    /// The chip matches what the repository field currently holds.
    let isSelected: Bool

    var id: String { path }
}

// MARK: - RecentRepos

/// The "Recent" row under the repository field: the label and one-line chips that wrap as whole chips.
/// Renders nothing when there are no chips.
struct RecentRepos: View {

    let repos: [RecentRepoModel]
    let onSelect: (String) -> Void

    var body: some View {
        if !repos.isEmpty {
            PillFlowLayout(spacing: HfRadius.Metrics.spacing6, rowAlignment: .center) {
                Text("Recent").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                ForEach(repos) { repo in
                    RecentRepoChip(repo: repo, onSelect: onSelect)
                }
            }
        }
    }
}

// MARK: - RecentRepoChip

/// One "Recent" chip: one line, truncated at the tail past the design's pill maximum.
struct RecentRepoChip: View {

    let repo: RecentRepoModel
    let onSelect: (String) -> Void

    var body: some View {
        Button { onSelect(repo.path) } label: {
            Text(repo.name)
                .font(.hf(.secondary))
                .foregroundStyle(repo.isSelected ? Color.accentLink : Color.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: HfRadius.Metrics.recentRepoChipMaxWidth)
                .padding(.horizontal, HfRadius.Metrics.spacing8)
                .padding(.vertical, HfRadius.Metrics.rowLineSpacing)
                // The selected chip is the design's tinted treatment: a running-tint
                // fill with accent text, in a capsule.
                .background(Capsule().fill(repo.isSelected ? Color.runningBG : Color.pillFill))
        }
        .buttonStyle(.plain)
        .help(repo.path)
        .accessibilityLabel("Recent repository \(repo.name)")
        .accessibilityHint(repo.path)
        .accessibilityAddTraits(repo.isSelected ? .isSelected : [])
    }
}

#if DEBUG
private let previewRepos = [
    RecentRepoModel(path: "/Users/me/Code/Carousell-iOS", name: "Carousell-iOS", isSelected: true),
    RecentRepoModel(path: "/Users/me/Code/Carousell-Android", name: "Carousell-Android", isSelected: false),
    RecentRepoModel(path: "/Users/me/Code/harflow", name: "harflow", isSelected: false)
]

#Preview("RecentRepos - light") {
    RecentRepos(repos: previewRepos, onSelect: { _ in })
        .padding(HfRadius.Metrics.spacing20)
        .frame(width: HfRadius.Metrics.newSessionSheetWidth - 2 * HfRadius.Metrics.spacing28)
        .background(Color.windowBG)
        .preferredColorScheme(.light)
}

#Preview("RecentRepos - dark") {
    RecentRepos(repos: previewRepos, onSelect: { _ in })
        .padding(HfRadius.Metrics.spacing20)
        .frame(width: HfRadius.Metrics.newSessionSheetWidth - 2 * HfRadius.Metrics.spacing28)
        .background(Color.windowBG)
        .preferredColorScheme(.dark)
}
#endif
