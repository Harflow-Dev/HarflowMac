import HfUI
import SwiftUI

// MARK: - SidebarBackendFilterLabel

/// The menu's decorative catalog dots and selected backend, with a separate chevron gutter.
struct SidebarBackendFilterLabel: View {
    let backendIDs: [String]
    let selectedTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HfRadius.Metrics.spacing2) { dots }.fixedSize()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: HfRadius.Metrics.sidebarFilterDotSize,
                                                     maximum: HfRadius.Metrics.sidebarFilterDotSize),
                                            spacing: HfRadius.Metrics.spacing2)], spacing: HfRadius.Metrics.spacing2) {
                    dots
                }
            }
            if let selectedTitle {
                Text(selectedTitle).font(.hf(.secondary, weight: .medium))
            }
        }
        // Reserve the gutter inside the overlay's bounds so the chevron cannot cover a dot.
        .padding(.trailing, HfRadius.Metrics.spacing12)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down").font(.hf(.caption, weight: .semibold))
        }
        .foregroundStyle(Color.secondaryText)
        .padding(.horizontal, HfRadius.Metrics.spacing10)
        .padding(.vertical, HfRadius.Metrics.spacing6)
        .background(RoundedRectangle(cornerRadius: HfRadius.row).fill(Color.pillFill))
    }

    private var dots: some View {
        ForEach(backendIDs, id: \.self) { backend in
            BackendDot(backend: backend, size: HfRadius.Metrics.sidebarFilterDotSize)
        }
    }
}

#if DEBUG
#Preview("Harness filter label - light") {
    SidebarBackendFilterLabel(backendIDs: ["claude", "codex", "vibe", "opencode", "antigravity", "cursor"], selectedTitle: nil)
        .fixedSize()
.preferredColorScheme(.light)
}

#Preview("Harness filter label - dark") {
    SidebarBackendFilterLabel(backendIDs: ["claude", "codex", "vibe", "opencode", "antigravity", "cursor"], selectedTitle: "Claude")
        .fixedSize()
.preferredColorScheme(.dark)
}

#Preview("Harness filter label - Reduce Motion") {
    SidebarBackendFilterLabel(backendIDs: (0 ..< 40).map { "backend-\($0)" }, selectedTitle: nil)
        .frame(width: HfRadius.Metrics.sidebarPreviewWidth - 2 * HfRadius.Metrics.spacing16)
        .preferredColorScheme(.dark)
.environment(\.hfReduceMotionOverride, true)
}
#endif
