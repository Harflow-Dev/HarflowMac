import AppKit
import Foundation
@testable import MainWindowFeature

// MARK: - ResourceSlotsShellEvidence reporting

extension ResourceSlotsShellEvidence {

    // MARK: Reporting

    func timelineSummary(limit: Int = 60) -> String {
        var lines: [(Int, String)] = []
        for change in changes {
            let axText = change.accessibility.map { "ax=\($0.identifier ?? "-")|\($0.role ?? "-")|\($0.text ?? "-")" } ?? "ax=pending"
            lines.append((change.seq, "#\(change.seq) responder[\(change.source)] c\(change.cycle) "
                + "\(change.from.summary) -> \(change.to.summary) \(axText)"))
        }
        for input in inputs {
            lines.append((input.startSeq, "#\(input.startSeq) input \(input.kind) -> \(input.target) gesture=\(input.backGesture) "
                + "release=\(input.release ?? "-") end=#\(input.endSeq.map(String.init) ?? "-")"))
        }
        for entry in diagnostics {
            lines.append((entry.seq, "#\(entry.seq) diag \(entry.event) c\(entry.cycle)"))
        }
        for stamp in stamps { lines.append((stamp.seq, "#\(stamp.seq) \(stamp.text)")) }
        let sorted = lines.sorted { $0.0 < $1.0 }.map(\.1)
        return sorted.suffix(limit).joined(separator: " | ")
    }

    /// Writes the buffered timeline into the trace once the run is over.
    func flush(to trace: ResourceSlotsNativeTrace) {
        trace.mark("shell-evidence-summary", details: ["variant": variant, "contentHost": contentHostDescription,
                                                       "outsideInput": String(outsideInput.count),
                                                       "priorLeakedEvent": priorLeakedEvent ?? "none",
                                                       "startOracle": startOracleLine ?? "none",
                                                       "gestureRelease": gestureRelease ?? "none",
                                                       "limit": "local monitor cannot see events consumed inside nested tracking loops"])
        for cycle in cycles {
            trace.mark("shell-cycle", details: [
                "cycle": String(cycle.id), "authorizedSeq": String(cycle.authorizedSeq),
                "authorizedResponder": cycle.authorizedResponder.summary,
                "authorizedResponderID": cycle.authorizedResponder.identity.map { String(describing: $0) } ?? "nil",
                "requestToken": cycle.requestToken?.uuidString ?? "none", "requestSeq": cycle.requestSeq.map(String.init) ?? "none",
                "terminal": cycle.terminalEvent ?? "none", "terminalSeq": cycle.terminalSeq.map(String.init) ?? "none",
                "backFired": backFiredPhase(cycle)])
        }
        for change in changes {
            trace.mark("shell-responder-change", details: [
                "seq": String(change.seq), "cycle": String(change.cycle), "token": change.token?.uuidString ?? "none",
                "source": change.source, "from": change.from.summary, "to": change.to.summary,
                "toID": change.to.identity.map { String(describing: $0) } ?? "nil",
                "axIdentifier": change.accessibility?.identifier ?? "nil", "axRole": change.accessibility?.role ?? "nil",
                "axText": change.accessibility?.text ?? "nil"])
        }
        for input in inputs {
            trace.mark("shell-input", details: [
                "start": String(input.startSeq), "end": input.endSeq.map(String.init) ?? "none", "kind": input.kind,
                "target": input.target, "responderAtSend": input.responderAtSend, "backGesture": String(input.backGesture),
                "release": input.release ?? "none", "matchClause": input.matchClause ?? "none", "tag": input.tag,
                "enqueuedAt": String(format: "%.4f", input.enqueuedAt),
                "deliveredAt": input.deliveredAt.map { String(format: "%.4f", $0) } ?? "none"])
        }
        for entry in diagnostics {
            trace.mark("shell-diagnostic", details: ["seq": String(entry.seq), "event": entry.event, "cycle": String(entry.cycle),
                                                     "token": entry.token?.uuidString ?? "none"])
        }
        for item in eventLog { trace.mark("shell-event-fields", details: ["seq": String(item.seq), "text": item.text]) }
        for item in stamps { trace.mark("shell-stamp", details: ["seq": String(item.seq), "text": item.text]) }
    }
}
