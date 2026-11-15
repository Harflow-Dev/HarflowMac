import AppKit
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - ObservationActionLayout

/// Adjacent observation actions wrap while retaining the approved eight point gap.
struct ObservationActionLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, point) in layout.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
        var maximum: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += height + 8; height = 0 }
            points.append(CGPoint(x: x, y: y))
            maximum = max(maximum, x + size.width)
            x += size.width + 8
            height = max(height, size.height)
        }
        return (CGSize(width: min(width, maximum), height: y + height), points)
    }
}

// MARK: - StoredRequestView

struct StoredRequestView: View {
    let state: TaskRequestReadState
    let read: (Int) -> Void
    let copy: (String) -> Void
    @State private var expanded: Bool
    @State private var textFocusIntent: StoredRequestFocusIntent?
    @State private var focusReplacement = false

    /// `initiallyExpanded` opens the disclosure on first draw (a Parallel lane's View prompt); the task screen keeps it closed.
    init(state: TaskRequestReadState, read: @escaping (Int) -> Void, copy: @escaping (String) -> Void, initiallyExpanded: Bool = false) {
        self.state = state
        self.read = read
        self.copy = copy
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                switch state {
                case .notRequested, .loading:
                    Text("Loading stored request")
                case let .failed(error, maxBytes):
                    Text(error.message)
                    Button("Retry request read") { readRequest(maxBytes) }
                case let .received(result, maxBytes):
                    received(result, maxBytes: maxBytes)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(heading).font(.hf(.secondary, weight: .semibold))
        }
        .onChange(of: state) { _, value in
            switch value {
            case .loading:
                cancelTextFocus()
            case .notRequested, .failed:
                focusReplacement = false
                cancelTextFocus()
            case .received:
                guard StoredRequestPresentation(state: value).text != nil else {
                    focusReplacement = false
                    cancelTextFocus()
                    return
                }
                if focusReplacement {
                    focusReplacement = false
                    cancelTextFocus()
                    textFocusIntent = StoredRequestFocusIntent()
                }
            }
        }
        .onChange(of: expanded) { _, value in
            if !value { focusReplacement = false; cancelTextFocus() }
        }
        .onDisappear { focusReplacement = false; cancelTextFocus() }
    }

    private func cancelTextFocus() {
        textFocusIntent?.cancel()
        textFocusIntent = nil
    }

    private var presentation: StoredRequestPresentation { StoredRequestPresentation(state: state) }
    private var heading: String { presentation.heading }

    private func full(_: TaskPromptResult) -> Bool { presentation.isFull }

    private func readRequest(_ maxBytes: Int) {
        ObservationAnnouncement.requested("Reading stored request")
        read(maxBytes)
    }

    @ViewBuilder private func received(_ value: TaskPromptResult, maxBytes: Int) -> some View {
        if value.state == .integrityFailed || value.integrity == .failed {
            Text("Questionable request text is withheld.")
            Button("Retry request read") { readRequest(65536) }
        } else if let text = value.text, value.state != .unavailable {
            Text(presentation.provenance ?? "")
                .font(.hf(.caption))
.foregroundStyle(.secondary)
            StoredRequestText(text: text, focusIntent: textFocusIntent) { consumed in
                if textFocusIntent === consumed { textFocusIntent = nil }
            }.frame(maxHeight: 180)
            ObservationActionLayout {
                Button(presentation.copyLabel ?? "Copy displayed text") { copy(text) }
                if let bound = presentation.readMoreBytes {
                    Button("Read more") { focusReplacement = true; readRequest(bound) }
                }
            }
            if !full(value), maxBytes >= 131072 {
                Text("This view's request limit has been reached. The full request is unavailable in this view.")
                    .font(.hf(.caption))
.foregroundStyle(.secondary)
            }
        } else {
            Text("The stored request is unavailable through the selected engine.")
            Button("Retry request read") { readRequest(65536) }
        }
    }
}

// MARK: - ObservationHistoryView

struct ObservationHistoryView: View {
    let frame: EventObservationFrame
    let action: (EventObservationAction) -> Void
    @FocusState private var boundaryFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status)
.font(.hf(.secondary))
.fixedSize(horizontal: false, vertical: true)
                .focusable()
.focused($boundaryFocused)
            if !frame.history.reasons.isEmpty {
                Text(frame.history.reasons.map(\.presentationText).sorted().joined(separator: " · "))
                    .font(.hf(.caption))
.foregroundStyle(.secondary)
            }
            if let failure = frame.history.failure {
                Text(failure.message).font(.hf(.caption)).textSelection(.enabled)
            }
            ObservationActionLayout {
                ForEach(actions, id: \.self) { value in
                    Button(label(value)) {
                        ObservationAnnouncement.requested(label(value))
                        action(value)
                        boundaryFocused = true
                    }.disabled(frame.history.isLoading)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: [EventObservationAction] {
        [.loadEarlier, .retryRead, .rebaseWindow, .adoptCurrentSource].filter { frame.history.availableActions.contains($0) }
    }

    private var status: String {
        if frame.history.currentness == .sourceChangePending { return "Activity source changed · cached history is not current" }
        if frame.history.currentness == .reconnecting {
            return frame.records.isEmpty ? "Captured history unavailable" : "Reconnecting · cached history is not current"
        }
        if frame.history.reasons.contains(.capacity) { return "This view's activity limit has been reached. Retained rows and reading position are preserved." }
        if frame.history.isLoading { return "Loading captured history" }
        if !frame.history.reasons.isEmpty { return "History incomplete or unavailable · see Events" }
        if frame.history.caughtUp { return "Captured activity caught up" }
        return "Available captured history · bounded window"
    }

    private func label(_ value: EventObservationAction) -> String {
        switch value {
        case .loadEarlier: "Load earlier"
        case .retryRead: "Retry history read"
        case .rebaseWindow: "Load current activity"
        case .adoptCurrentSource: "Load current activity from new source"
        }
    }
}

// MARK: - PublicEventsPresentation

/// What the Events pane draws around the captured records, decided from one observation frame.
///
/// Pure and derived in the view from the domain frame: it adds no published view-model state. Records keep rendering
/// from `EventObservationFrame.records`; this value only decides the summary block, the history note, the pane's
/// "Load earlier" button and the section caption.
struct PublicEventsPresentation: Equatable, Sendable {
    /// The tool-activity line drawn under "Captured activity facts".
    enum Summary: Equatable, Sendable {
        /// No frame has been published yet.
        case loadingRecords
        /// The summary is still loading.
        case loading
        /// Observed counts with at least one tool call.
        case counts(toolCalls: Int, edits: Int, commands: Int)
        /// Observed, with records present but no tool calls.
        case noToolCalls
        /// Any other non-observed summary state.
        case unavailable
        /// An empty, current, fully read window: no summary line is drawn.
        case none
    }

    /// The warning note above the captured activity.
    enum Note: Equatable, Sendable {
        /// The history read failed and a retry is on offer.
        case historyUnavailable
        /// Only the earlier-page read failed; the retained records stay and a retry re-reads that page.
        case earlierPageUnreadable
    }

    let summary: Summary
    let note: Note?
    /// An empty window that was read completely and is current.
    let isEmptyWindow: Bool
    /// Whether the pane offers "Load earlier" between the caption and the records.
    let showsLoadEarlier: Bool
    /// Whether the "Public normalized events" caption is drawn.
    let showsRecordsCaption: Bool

    // MARK: Building

    /// Derives the presentation from the observation frame, or from none while it loads.
    static func make(from frame: EventObservationFrame?) -> PublicEventsPresentation {
        guard let frame else {
            return PublicEventsPresentation(summary: .loadingRecords, note: nil, isEmptyWindow: false,
                                            showsLoadEarlier: false, showsRecordsCaption: true)
        }
        let actions = frame.history.availableActions
        let retry = actions.contains(.retryRead)
        let empty = frame.summary.state == .observed && frame.records.isEmpty && !frame.history.isLoading
            && frame.history.failure == nil && frame.history.currentness == .current && !retry
        let summary: Summary = if empty {
            .none
        } else if frame.summary.state == .observed, let counts = frame.summary.counts {
            counts.toolCalls == 0 ? .noToolCalls
                : .counts(toolCalls: counts.toolCalls, edits: counts.edits, commands: counts.commands)
        } else {
            frame.summary.state == .loading ? .loading : .unavailable
        }
        let note: Note? = if retry {
            (frame.history.olderReadFailed && !frame.records.isEmpty && !actions.contains(.rebaseWindow))
                ? .earlierPageUnreadable : .historyUnavailable
        } else {
            nil
        }
        return PublicEventsPresentation(summary: summary, note: note,
                                        isEmptyWindow: empty, showsLoadEarlier: actions.contains(.loadEarlier) && !retry,
                                        showsRecordsCaption: !empty)
    }
}

// MARK: - PublicEventsView

struct PublicEventsView: View {
    let frame: EventObservationFrame?
    let recovered: RecoveredTranscriptFrame
    let copy: (String) -> Void
    let action: (EventObservationAction) -> Void
    /// The heading is a tab stop only after a pane history action has asked for focus.
    @State private var focusArmed = false
    @FocusState private var headingFocused: Bool
    @AccessibilityFocusState private var headingAccessibilityFocused: Bool

    var body: some View {
        let presentation = PublicEventsPresentation.make(from: frame)
        VStack(alignment: .leading, spacing: 12) {
            if let frame {
                if !presentation.isEmptyWindow { heading("Captured activity facts") }
                summaryLine(presentation.summary)
                activityHeading
                if presentation.note == .historyUnavailable {
                    historyNote(frame, title: "Captured history unavailable",
                                body: "The read could not be completed. This does not mean the task failed.")
                }
                if presentation.isEmptyWindow {
                    Text("No rows in the available captured history")
                    Text("An empty window does not qualify totals.").font(.hf(.caption)).foregroundStyle(.secondary)
                }
                if presentation.showsRecordsCaption {
                    Text("Public normalized events · bounded record window").font(.hf(.secondary, weight: .semibold))
                }
                if presentation.note == .earlierPageUnreadable {
                    historyNote(frame, title: "Earlier records couldn't be read",
                                body: "Records below stay. Retrying reads the same earlier page again.")
                }
                if presentation.showsLoadEarlier {
                    Button("Load earlier") { perform(.loadEarlier, label: "Load earlier") }
                        .accessibilityIdentifier("task-events.load-earlier")
                }
                ForEach(frame.records) { observed in
                    let json = observed.normalizedJSON
                    DisclosureGroup {
                        Text(verbatim: json).font(.hf(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy normalized record") { copy(json) }
                    } label: {
                        Text(observed.record.raw["kind"]?.stringValue ?? "Unsupported normalized record")
                            .font(.hf(.secondary))
                    }
                }
            } else {
                Text("Public normalized events · bounded record window").font(.hf(.secondary, weight: .semibold))
                Text("Loading captured records")
            }
            if !recovered.items.isEmpty {
                Divider()
                Text("Recovered transcript").font(.hf(.secondary, weight: .semibold))
                Text("Display-only recovered material · excluded from captured activity facts").font(.hf(.caption))
                ForEach(recovered.events) { event in
                    Text(verbatim: event.rawLine).font(.hf(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.hf(.secondary, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }

    /// The persistent "Captured activity" heading; it takes keyboard and accessibility focus after a pane history action.
    private var activityHeading: some View {
        heading("Captured activity")
            .focusable(focusArmed)
            .focused($headingFocused)
            .accessibilityFocused($headingAccessibilityFocused)
            .onChange(of: focusArmed) { _, armed in
                // The heading became focusable in the update that just rendered, so the focus request can now land.
                if armed { moveFocusToHeading() }
            }
            .onChange(of: headingFocused) { _, focused in
                // Losing keyboard focus disarms the heading, so it is not a permanent tab stop.
                if !focused { focusArmed = false }
            }
    }

    @ViewBuilder private func summaryLine(_ summary: PublicEventsPresentation.Summary) -> some View {
        switch summary {
        case .loadingRecords, .none: EmptyView()
        case .loading: Text("Loading tool activity")
        case .noToolCalls: Text("No tool calls observed in the available captured history")
        case let .counts(toolCalls, edits, commands): Text("\(toolCalls) tool calls observed · \(edits) edits · \(commands) commands")
        case .unavailable: Text("Tool activity unavailable")
        }
    }

    private func historyNote(_ frame: EventObservationFrame, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TaskScreenStyle.sans(size: 13).weight(.semibold))
                    .foregroundStyle(TaskScreenStyle.Colors.text.color)
                Text(body)
                    .font(TaskScreenStyle.sans(size: 13))
                    .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
            }
            .accessibilityElement(children: .combine)
            Button("Retry history read") { perform(.retryRead, label: "Retry history read") }
                .controlSize(.small)
                .disabled(frame.history.isLoading)
                .padding(.top, 8)
                .accessibilityIdentifier("task-events.retry-history-read")
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusMedium).fill(TaskScreenStyle.Notice.warning.background.color))
        .accessibilityElement(children: .contain)
    }

    private func perform(_ value: EventObservationAction, label: String) {
        ObservationAnnouncement.requested(label)
        action(value)
        // Arm first: the focus request is issued from `onChange(of: focusArmed)`, after the heading is focusable. When the
        // heading is already armed (it still holds focus) no change fires, so the request is issued directly.
        if focusArmed { moveFocusToHeading() } else { focusArmed = true }
    }

    private func moveFocusToHeading() {
        headingFocused = true
        headingAccessibilityFocused = true
    }
}

// MARK: - ObservationAnnouncement

/// Explicit read actions announce once; polling publications never call this boundary.
@MainActor private enum ObservationAnnouncement {
    static func requested(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

#if DEBUG
#Preview("Original request · synthetic stored text") {
    StoredRequestView(state: TaskDetailViewModelMock.previewRequest(), read: { _ in }, copy: { _ in })
        .padding(16)
.frame(width: 480)
}

#Preview("History · observed synthetic window") {
    ObservationHistoryView(frame: TaskDetailViewModelMock.previewObservation(), action: { _ in })
        .padding(16)
.frame(width: 480)
}

#Preview("Events · public normalized synthetic record") {
    ScrollView {
        PublicEventsView(frame: TaskDetailViewModelMock.previewObservation(), recovered: .init(), copy: { _ in }, action: { _ in })
            .padding(16)
    }.frame(width: 320, height: 420)
}

#Preview("Events · page with Load earlier") {
    ScrollView {
        PublicEventsView(frame: TaskDetailViewModelMock.previewObservation(actions: [.loadEarlier]), recovered: .init(),
                         copy: { _ in }, action: { _ in })
            .padding(16)
    }.frame(width: 320, height: 420)
}

#Preview("Events · empty window") {
    ScrollView {
        PublicEventsView(frame: TaskDetailViewModelMock.previewObservation(empty: true), recovered: .init(),
                         copy: { _ in }, action: { _ in })
            .padding(16)
    }.frame(width: 320, height: 420)
}

#Preview("Events · history unavailable") {
    ScrollView {
        PublicEventsView(frame: TaskDetailViewModelMock.previewObservation(actions: [.retryRead]), recovered: .init(),
                         copy: { _ in }, action: { _ in })
            .padding(16)
    }.frame(width: 320, height: 420)
}

#Preview("Events · earlier page unreadable") {
    ScrollView {
        PublicEventsView(frame: TaskDetailViewModelMock.previewObservation(actions: [.retryRead], olderReadFailed: true),
                         recovered: .init(), copy: { _ in }, action: { _ in })
            .padding(16)
    }.frame(width: 320, height: 420)
}

#Preview("Wrapping observation actions") {
    ObservationActionLayout {
        Button("Load earlier") {}
        Button("New activity · show") {}
        Button("Retry history read") {}
    }
.padding(16)
.frame(width: 240)
}
#endif
