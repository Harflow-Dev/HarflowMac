#if DEBUG

import Foundation
import HfCommon
import HfRepository
import MonitorCore

// MARK: - NeedsYouViewModelMock

/// Preview mock for `NeedsYouView`.
@MainActor
@Observable
final class NeedsYouViewModelMock: NeedsYouViewModel {
    var presentation: NeedsYouPresentation
    var answerText: String
    var additionalAttempts = 1

    init(presentation: NeedsYouPresentation, answerText: String = "") {
        self.presentation = presentation
        self.answerText = answerText
    }

    func didAppear() {}
    func didDisappear() {}
    func show(itemID _: String?) {}
    func didSelect(_: String) {}
    func didTapBack() {}
    func didTapRetry() {}
    func didDismissNotice() {}
    func didSubmitAnswer() {}
    func didChooseOffered(_: String) {}
    func didDecide(approve _: Bool) {}
    func didChangeReduceMotion(_: Bool) {}
}

// MARK: - NeedsYouPreviewFixtures

enum NeedsYouPreviewFixtures {
    static let now = Date()

    private static func ownership(ended: Bool = true, owner: String = "caller", handover: Bool = false) -> NeedsYouItem.Ownership {
        NeedsYouItem.Ownership(
            owner: owner, callerEnded: ended, engineNote: ended ? "The caller process is no longer running." : "",
            handover: handover
                ? .init(timestamp: now.addingTimeInterval(-1080), reason: "The caller process was no longer running.", previousOwner: "caller")
                : nil
        )
    }

    static let longQuestion = "Two deployment targets are available for this release: the existing staging cluster in the eu-west region, "
        + "and the preview environment created by the last workflow run. The preview environment has no monitoring.\n\n"
        + "Which target should this release use? Reply with the target name and, if relevant, the postponement decision."

    static let veryLongQuestion = (1 ... 9)
.map {
        "\($0). Item \($0) of the migration inventory lists a table, its row count and the owner who last changed it. "
            + "State whether it stays in place, moves to the archive schema, or is dropped after the export finishes."
    }
.joined(separator: "\n\n")

    static func question(_ id: String = "input:w1:d1", text: String = longQuestion, minutes: Double = 42, handover: Bool = false) -> NeedsYouItem {
        NeedsYouItem(
            id: id, kind: .question, rootRunID: "w1", sourceRunID: "w1", runTitle: "Release checklist",
            pathTitles: ["Release checklist", "Choose deployment target"], text: text,
            ownership: ownership(owner: handover ? "monitor" : "caller", handover: handover),
            startedBy: handover ? "Original caller" : "Original caller", waitingSince: now.addingTimeInterval(-minutes * 60), decisionID: "d1"
        )
    }

    static func recovery() -> NeedsYouItem {
        NeedsYouItem(
            id: "attention:w2:w2:abcd1234", kind: .recovery, rootRunID: "w2", sourceRunID: "w2", runTitle: "Audit lockfile",
            pathTitles: ["Audit lockfile", "Check versions"],
            text: "The node reached its attempt limit (3 of 3) while checking the lockfile. Say which version to keep, then resume.",
            ownership: ownership(), startedBy: "Original caller", waitingSince: now.addingTimeInterval(-3000), canAddAttempts: true
        )
    }

    static func approval(taskApproval: Bool = false) -> NeedsYouItem {
        let request = CallerApprovalRequest(raw: [
            "request_id": .string("r1"), "task_id": .string("t1"), "interaction_owner": .string(taskApproval ? "caller" : "monitor"),
            "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("./scripts/apply-schema.sh --target staging")])])
        ])
        return NeedsYouItem(
            id: "approval:t1:r1", kind: .approval, runTitle: taskApproval ? "Add retry to webhook client" : "Migrate billing exports",
            pathTitles: taskApproval ? ["Add retry to webhook client"] : ["Migrate billing exports", "Verify exports", "Apply schema change"],
            text: "Bash: ./scripts/apply-schema.sh --target staging", ownership: ownership(ended: !taskApproval),
            startedBy: "Original caller", waitingSince: now.addingTimeInterval(-540), approval: request, taskID: "t1"
        )
    }

    static func presentation(items: [NeedsYouItem], mutate: (inout NeedsYouPresentation) -> Void = { _ in }) -> NeedsYouPresentation {
        var value = NeedsYouPresentationMapper.presentation(NeedsYouSnapshot(phase: .ready, items: items), leaving: [])
        mutate(&value)
        return value
    }

    static func detail(_ item: NeedsYouItem, mutate: (inout NeedsYouDetail) -> Void = { _ in }) -> NeedsYouPresentation {
        var detail = NeedsYouPresentationMapper.detail(item)
        mutate(&detail)
        return presentation(items: [item]) {
            $0.showsDetail = true
            $0.detail = detail
        }
    }
}

#endif
