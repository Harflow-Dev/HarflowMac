import PbUI
import SwiftUI

// MARK: - SidebarBackendFilterLabel

/// The menu's decorative catalog dots and selected backend, with a separate chevron gutter.
struct SidebarBackendFilterLabel: View {
    let backendIDs: [String]
    let selectedTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PbRadius.Metrics.spacing2) { dots }.fixedSize()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: PbRadius.Metrics.sidebarFilterDotSize,
                                                     maximum: PbRadius.Metrics.sidebarFilterDotSize),
                                            spacing: PbRadius.Metrics.spacing2)], spacing: PbRadius.Metrics.spacing2) {
                    dots
                }
            }
            if let selectedTitle {
                Text(selectedTitle).font(.pb(.secondary, weight: .medium))
            }
        }
        // Reserve the gutter inside the overlay's bounds so the chevron cannot cover a dot.
        .padding(.trailing, PbRadius.Metrics.spacing12)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.down").font(.pb(.caption, weight: .semibold))
        }
        .foregroundStyle(Color.secondaryText)
        .padding(.horizontal, PbRadius.Metrics.spacing10)
        .padding(.vertical, PbRadius.Metrics.spacing6)
        .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.pillFill))
    }

    private var dots: some View {
        ForEach(backendIDs, id: \.self) { backend in
            BackendDot(backend: backend, size: PbRadius.Metrics.sidebarFilterDotSize)
        }
    }
}

#if DEBUG
#Preview("Backend filter label - light") {
    SidebarBackendFilterLabel(backendIDs: ["claude", "codex", "vibe", "opencode", "antigravity"], selectedTitle: nil)
        .fixedSize()
.preferredColorScheme(.light)
}

#Preview("Backend filter label - dark") {
    SidebarBackendFilterLabel(backendIDs: ["claude", "codex", "vibe", "opencode", "antigravity"], selectedTitle: "Claude")
        .fixedSize()
.preferredColorScheme(.dark)
}

#Preview("Backend filter label - Reduce Motion") {
    SidebarBackendFilterLabel(backendIDs: (0 ..< 40).map { "backend-\($0)" }, selectedTitle: nil)
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth - 2 * PbRadius.Metrics.spacing16)
        .preferredColorScheme(.dark)
.environment(\.pbReduceMotionOverride, true)
}
#endif
