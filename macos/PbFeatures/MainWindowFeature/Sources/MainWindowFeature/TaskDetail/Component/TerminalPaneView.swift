//
//  TerminalPaneView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TerminalPane.swift`. Hosts the session's `NSView` via
//  `PbTerminal.TerminalHost`, which lives with the session, so switching tabs never restarts the
//  process. The status texts are derived from the live `@Published` session fields by
//  `TerminalPaneModel.build(from:)` — a pure function (`TerminalSession.pid`/`ended`/`attached`/
//  `attachError`/`terminating` are read-only outside `PbTerminal`, so the reservation-text rule is
//  additionally exposed as `reservationText(kind:ended:attached:hasAttachError:)`, testable on
//  primitives without a live session).
//

import PbTerminal
import PbUI
import SwiftUI

// MARK: - TerminalPaneModel

struct TerminalPaneModel {
    let statusLine: String
    let sizeLabel: String
    let pidLabel: String?
    let reservationText: String?
    let reservationIsGreen: Bool
    let isEnded: Bool
    let isTerminating: Bool
    let attachError: String?
    
    @MainActor
    static func build(from session: TerminalSession) -> TerminalPaneModel {
        let reservation = reservationText(kind: session.kind, ended: session.ended, attached: session.attached, hasAttachError: session.attachError != nil)
        return TerminalPaneModel(
            statusLine: session.statusLine,
            sizeLabel: "zsh · \(session.size)",
            pidLabel: session.pid.map { "pid \($0)" },
            reservationText: reservation?.text,
            reservationIsGreen: reservation?.isGreen ?? false,
            isEnded: session.ended,
            isTerminating: session.terminating,
            attachError: session.attachError
        )
    }
    
    /// `TerminalPane.swift:24-32`: once the process is gone polybridge releases the reservation, so
    /// the "reservation released" text only ever follows a session that really was attached — never
    /// an ended session that was never attached at all. `nil` for an interactive (non-takeover)
    /// session, which never reserves anything.
    static func reservationText(kind: TerminalSession.Kind, ended: Bool, attached: Bool, hasAttachError: Bool) -> (text: String, isGreen: Bool)? {
        guard case .takeover = kind else { return nil }
        if ended {
            return (attached ? "ended · reservation released" : "ended", false)
        }
        if attached { return ("session reserved", true) }
        return (hasAttachError ? "not attached" : "attaching…", false)
    }
}

// MARK: - TerminalPaneView

struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    let onEndSession: () -> Void
    let onClose: () -> Void
    
    private var model: TerminalPaneModel { .build(from: session) }
    
    var body: some View {
        VStack(spacing: 0) {
            TerminalHost(session: session)
                .background(Color.black)
            Divider()
            HStack(spacing: 14) {
                Text(model.statusLine)
                Text(model.sizeLabel).monospacedDigit()
                if let pidLabel = model.pidLabel { Text(pidLabel).monospacedDigit() }
                if let reservationText = model.reservationText {
                    Text(reservationText).foregroundStyle(model.reservationIsGreen ? Color.doneGreen : (model.isEnded ? .secondary : Color.failedRed))
                }
                Spacer()
                if model.isEnded {
                    Button("Close", action: onClose)
                } else {
                    Button(model.isTerminating ? "Ending…" : "End session", action: onEndSession)
                        .disabled(model.isTerminating)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if let error = model.attachError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.failedRed).padding(8)
            }
        }
    }
}
