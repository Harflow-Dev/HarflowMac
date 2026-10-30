#if DEBUG

import HfRepository
import SwiftUI

// MARK: - Previews

private typealias Fixtures = NeedsYouPreviewFixtures

@MainActor
private func screen(_ presentation: NeedsYouPresentation, answer: String = "", scheme: ColorScheme) -> some View {
    NeedsYouView(NeedsYouViewModelMock(presentation: presentation, answerText: answer), itemID: nil)
        .frame(width: 820, height: 640)
        .preferredColorScheme(scheme)
}

@MainActor
private var allItems: [NeedsYouItem] {
    [Fixtures.question(), Fixtures.recovery(), Fixtures.approval(), Fixtures.question("input:w3:d3", text: "Who is the audience?", minutes: 3, handover: true)]
}

#Preview("List · populated · light") { screen(Fixtures.presentation(items: allItems), scheme: .light) }
#Preview("List · populated · dark") { screen(Fixtures.presentation(items: allItems), scheme: .dark) }
#Preview("List · single") { screen(Fixtures.presentation(items: [Fixtures.approval()]), scheme: .light) }
#Preview("List · empty") { screen(Fixtures.presentation(items: []), scheme: .light) }
#Preview("List · loading") { screen(NeedsYouPresentation(), scheme: .light) }
#Preview("List · partial error") {
    screen(Fixtures.presentation(items: allItems) { $0.partialNotice = "Could not read 2 runs. Showing the requests Harflow could read." }, scheme: .light)
}

#Preview("List · request arrives") {
    screen(Fixtures.presentation(items: allItems) { $0.notice = "The caller is answering this again." }, scheme: .light)
}

#Preview("List · older engine") {
    screen(Fixtures.presentation(items: [Fixtures.approval(taskApproval: true)]) {
        $0.olderEngineNote = "This engine version cannot report workflow questions here. Only task approvals are listed."
    }, scheme: .light)
}

#Preview("Detail · answerable · light") { screen(Fixtures.detail(Fixtures.question()), scheme: .light) }
#Preview("Detail · answerable · dark") { screen(Fixtures.detail(Fixtures.question()), scheme: .dark) }
#Preview("Detail · handed over") { screen(Fixtures.detail(Fixtures.question(handover: true)), scheme: .light) }
#Preview("Detail · approval") { screen(Fixtures.detail(Fixtures.approval()), scheme: .light) }
#Preview("Detail · task approval") { screen(Fixtures.detail(Fixtures.approval(taskApproval: true)), scheme: .light) }
#Preview("Detail · submitting") {
    screen(Fixtures.detail(Fixtures.question()) { $0.phase = .submitting }, answer: "Use staging.", scheme: .light)
}

#Preview("Detail · answered") {
    screen(Fixtures.detail(Fixtures.question()) {
        $0.phase = .settled(decision: "Answered", answer: "Use staging.", note: "Harflow now owns this run. The original caller can no longer answer it.")
    }, scheme: .light)
}

#Preview("Detail · expired") { screen(Fixtures.detail(Fixtures.question()) { $0.phase = .expired }, scheme: .light) }
#Preview("Detail · refused") {
    screen(Fixtures.detail(Fixtures.question()) {
        $0.error = "This request changed after you opened it. Review the current question, then send again."
    }, answer: "Use staging.", scheme: .light)
}

#Preview("Detail · recovery") { screen(Fixtures.detail(Fixtures.recovery()), scheme: .light) }
#Preview("Detail · very long") {
    screen(Fixtures.detail(Fixtures.question(text: Fixtures.veryLongQuestion)), scheme: .dark)
}

#endif
