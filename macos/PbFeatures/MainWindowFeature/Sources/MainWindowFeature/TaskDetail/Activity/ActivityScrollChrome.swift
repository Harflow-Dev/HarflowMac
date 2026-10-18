//
//  ActivityScrollChrome.swift
//  MainWindowFeature
//
//  Compatibility adapter (adjudicated scrollbar plan step 3): the Phase 4 activity-only chrome
//  owner and its private registry are retired. The three activity-feed mounts
//  (`ActivityFeedView`, `ParallelColumnView`'s result callout, `WorkflowNativeActivity`) keep their
//  names but route through PbUI's shared `ScrollChrome` document probe and its single
//  weak-key/weak-value owner registry — there are no longer two competing registries. The shared
//  probe keeps the proven lifecycle: original-chrome capture before any write, per-attachment
//  tokens, preference-change reassertion, and last-detach restoration with the off-window
//  skip. Under the monitor-wide amendment it attaches while EITHER axis is enabled and sizes
//  every ENABLED axis small, where the activity-only owner sized the vertical scroller alone —
//  the feeds enable only their vertical axis, so their presentation is unchanged.
//
//  The former unit tests that pinned the retired owner/registry internals move to PbUI's shared
//  owner suite, with the superseded horizontal expectation updated to `.small` under the new
//  authorization.
//

import PbUI
import SwiftUI

// MARK: - ActivityScrollChrome

/// The shared document probe under its activity-feed name, so the pre-existing feed call sites
/// keep compiling against the one shared implementation.
typealias ActivityScrollChrome = ScrollChrome

// MARK: - ActivityScrollChromeView

/// The shared noninteractive attachment view under its activity-feed name, so the DesignReference
/// capture probes keep discovering the feed's own scroll view through the shared probe's view.
typealias ActivityScrollChromeView = ScrollChromeAttachmentView

#if DEBUG
/// Overflowing dummy data — the alias routes through the shared probe, whose native indicator
/// fades at rest.
private struct ActivityScrollChromePreview: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PbRadius.Metrics.spacing20) {
                ForEach(PreviewFixtures.sampleRows(taskID: "chrome-preview")) { row in
                    TimelineRow(model: TimelineRowModel(item: PreviewFixtures.textItem(
                        "Scroll me — the indicator fades at rest. Row \(row.id)."
                    ), start: row.timestamp, live: false, showsPromptBubble: false))
                }
            }
            .padding(PbRadius.Metrics.spacing16)
            .background(ActivityScrollChrome())
        }
        .frame(width: PbRadius.Metrics.activityPreviewWidth * 2, height: PbRadius.Metrics.foundationHeight / 2)
        .background(Color.windowBG)
    }
}

#Preview("ActivityScrollChrome - light") {
    ActivityScrollChromePreview().preferredColorScheme(.light)
}

#Preview("ActivityScrollChrome - dark") {
    ActivityScrollChromePreview().preferredColorScheme(.dark)
}
#endif
