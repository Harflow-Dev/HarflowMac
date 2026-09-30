//
//  RecentRepos.swift
//  MainWindowFeature
//

import PbUI
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

/// The "Recent" row under the repository field. Renders nothing when there are no chips.
struct RecentRepos: View {

    let repos: [RecentRepoModel]
    let onSelect: (String) -> Void

    var body: some View {
        if !repos.isEmpty {
            HStack(spacing: 6) {
                Text("Recent").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                ForEach(repos) { repo in
                    Button { onSelect(repo.path) } label: {
                        Text(repo.name)
                            .font(.pb(.secondary))
                            .foregroundStyle(repo.isSelected ? Color.accentLink : Color.primary.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(repo.isSelected ? Color.accentLink.opacity(0.12) : Color.pillFill))
                    }
                    .buttonStyle(.plain)
                    .help(repo.path)
                    .accessibilityLabel("Recent repository \(repo.name)")
                    .accessibilityHint(repo.path)
                    .accessibilityAddTraits(repo.isSelected ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
        }
    }
}

#if DEBUG
private let previewRepos = [
    RecentRepoModel(path: "/Users/me/Code/Carousell-iOS", name: "Carousell-iOS", isSelected: true),
    RecentRepoModel(path: "/Users/me/Code/Carousell-Android", name: "Carousell-Android", isSelected: false),
    RecentRepoModel(path: "/Users/me/Code/polybridge", name: "polybridge", isSelected: false)
]

#Preview("RecentRepos - light") {
    RecentRepos(repos: previewRepos, onSelect: { _ in })
        .padding(20)
.frame(width: 600)
.background(Color.windowBG)
.preferredColorScheme(.light)
}

#Preview("RecentRepos - dark") {
    RecentRepos(repos: previewRepos, onSelect: { _ in })
        .padding(20)
.frame(width: 600)
.background(Color.windowBG)
.preferredColorScheme(.dark)
}
#endif
