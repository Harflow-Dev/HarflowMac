//
//  ActivityUpdateToken.swift
//  MainWindowFeature
//
//  Follow live scrolls when this changes. It is derived from the raw rows only, so it moves on a new
//  row, a card growing, a tool result landing in place and streaming text — and never on a card
//  being expanded or collapsed, which is view state the model does not know about.
//

import Foundation
import MonitorCore

// MARK: - ActivityUpdateToken

struct ActivityUpdateToken: Equatable {
    let rowCount: Int
    let fingerprint: Int

    init(rows: [ConversationTimelineRow], liveStep: LiveStep?) {
        self.rowCount = rows.count
        var hasher = Hasher()
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.live)
            guard case .item(let item) = row.kind else { continue }
            switch item.body {
            case .tool(_, let result):
                hasher.combine(result != nil)
                hasher.combine(result?.ok)
                hasher.combine(result?.outputTail.utf8.count)
            case .text(let text, let streaming):
                hasher.combine(text.utf8.count)
                hasher.combine(streaming)
            default:
                break
            }
        }
        hasher.combine(liveStep?.text)
        self.fingerprint = hasher.finalize()
    }

    static let empty = ActivityUpdateToken(rows: [], liveStep: nil)
}
