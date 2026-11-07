//
//  ActivityFeedStyle.swift
//  MainWindowFeature
//
//  The activity feed's presentation style. `.standard` is the look every surface had before the task
//  screen's transcript metrics: it is the default everywhere and renders unchanged. `.transcript` applies
//  `TaskScreenStyle`'s transcript, prose, bubble, tool-row and working-row metrics, and is requested only
//  by the standalone task and Group mounts of the task detail.
//

import AppKit
import SwiftUI

// MARK: - ActivityFeedStyle

enum ActivityFeedStyle: Equatable, Sendable {
    case standard
    case transcript

    var isTranscript: Bool { self == .transcript }

    /// The feed's horizontal padding for a caller whose standard padding is `standard`.
    func horizontalPadding(standard: CGFloat) -> CGFloat {
        isTranscript ? TaskScreenStyle.Transcript.paddingHorizontal : standard
    }

    /// The top spacing of an entry that follows other content (`gap`) or opens the feed (`first`).
    /// The standard values are the feed's established 20 and 12.
    func spacing(first: Bool, standardFirst: CGFloat, standardBetween: CGFloat) -> CGFloat {
        switch self {
        case .standard: first ? standardFirst : standardBetween
        case .transcript: first ? TaskScreenStyle.Transcript.paddingTop : TaskScreenStyle.Transcript.gap
        }
    }
}

extension ActivityFeedStyle {
    /// The fill of a pill: the palette's `pillFill`, or `surface-sunken` in the transcript (the palette fill
    /// nearly vanishes on the dark page).
    var pillFill: Color { isTranscript ? TaskScreenStyle.Colors.surfaceSunken.color : Color.pillFill }
    /// The fill of a code block, by the same rule.
    var codeFill: Color { isTranscript ? TaskScreenStyle.Colors.surfaceSunken.color : Color.codeFill }
    /// The colour of a hairline rule: the palette's `hairline`, or `border` in the transcript.
    var ruleColor: Color { isTranscript ? TaskScreenStyle.Colors.border.color : Color.hairline }
}

extension EnvironmentValues {
    /// The style of the activity feed hosting this view; `.standard` outside the task transcript.
    @Entry var activityFeedStyle = ActivityFeedStyle.standard
}

// MARK: - Transcript metrics

extension TaskScreenStyle {
    /// A fixed-size system font for a design size outside HfUI's type scale (inline code at 12.5 pt).
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight))
    }

    /// Extra line spacing that brings a system-font line of `size` to `lineHeight`.
    static func lineSpacing(_ spec: TextSpec) -> CGFloat {
        let font = NSFont.systemFont(ofSize: spec.size)
        return max(0, spec.lineHeight - ceil(font.ascender - font.descender + font.leading))
    }

    /// `.hd-msg-agent` / `.hd-msg-user` line spacing, resolved once.
    static let bodyLineSpacing = lineSpacing(AgentProse.text)
    /// `.hd-tool__head` line spacing, resolved once.
    static let toolHeadLineSpacing = lineSpacing(ToolHead.text)
    /// `.hd-tool__body` line spacing, resolved once (monospaced line of 12 pt).
    static let toolBodyLineSpacing: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: ToolBody.text.size, weight: .regular)
        return max(0, ToolBody.text.lineHeight - ceil(font.ascender - font.descender + font.leading))
    }()
}
