//
//  TopBarTestSupport.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import MonitorCore

// MARK: - TopBarFixtures

/// Plain values shared by the top bar suites.
@MainActor
enum TopBarFixtures {

    static func content(title: String = "Title", badge: String? = nil, paneOpen: Bool = false, notices: Int = 0,
                        continuity: Bool = false, access: String? = "Read-only") -> TaskTopBarContent {
        let evidence = TaskSnapshotEvidence(status: .running, takenOver: false, snapshotStatus: nil, exitCode: nil, logState: nil)
        var model = TaskBadgeModel.make(evidence: evidence, startedAt: nil)
        if let badge { model = TaskBadgeModel(icon: model.icon, tone: model.tone, label: badge, clock: .none, suffix: nil) }
        return TaskTopBarContent(
            title: title, badge: model, metaParts: ["claude", "repo"], isBusy: false, isPending: false, paneOpen: paneOpen,
            showsContinuity: continuity, noticeCount: notices, accessText: access, startedAt: nil
        )
    }

    /// An object whose identity stands for a writer.
    final class Writer {}

    /// Writers stay alive for the process so two tags never share a reused object identity.
    private static var retained: [Writer] = []

    static func tag(_ writer: Writer, _ conversation: String) -> TaskTopBarHolder.Tag {
        retained.append(writer)
        return TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), conversationID: conversation)
    }
}
