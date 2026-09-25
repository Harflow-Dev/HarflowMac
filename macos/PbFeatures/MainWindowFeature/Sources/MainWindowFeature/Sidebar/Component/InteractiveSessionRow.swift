//
//  InteractiveSessionRow.swift
//  MainWindowFeature
//
//  Ported from the old `SidebarView.swift`'s inline "Interactive" section row. Only this screen
//  uses this shape, so it stays local rather than moving to PbUI (unlike `TaskRow`).
//

import PbUI
import SwiftUI

// MARK: - InteractiveSessionRowModel

/// Presentation data for one row in the sidebar's "Interactive" section.
struct InteractiveSessionRowModel: Identifiable, Equatable {
    let id: UUID
    let backend: String
    let title: String
}

// MARK: - InteractiveSessionRow

/// A single interactive-session row: badge, title, a green "live" dot. Dumb component — no logic
/// beyond layout.
struct InteractiveSessionRow: View {
    let model: InteractiveSessionRowModel
    
    var body: some View {
        HStack {
            BackendBadge(backend: model.backend, size: 18)
            Text(model.title).lineLimit(1)
            Spacer()
            Circle().fill(Color.doneGreen).frame(width: 6, height: 6)
        }
    }
}

#if DEBUG
#Preview {
    InteractiveSessionRow(model: InteractiveSessionRowModel(id: UUID(), backend: "claude", title: "claude · ~/repo"))
        .padding()
        .frame(width: 260)
}
#endif
