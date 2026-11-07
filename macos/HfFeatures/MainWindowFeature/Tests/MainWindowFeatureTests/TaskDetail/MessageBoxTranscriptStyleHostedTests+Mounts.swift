import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import SwiftUI
import Testing

// MARK: - MessageBoxTranscriptStyleHostedTests + mounts

/// Which surfaces mount which `MessageBoxStyle`, and that `.standard` still renders as it did at the base commit.
extension MessageBoxTranscriptStyleHostedTests {

    // MARK: Defaults and mounts

    @Test func givenMessageBoxView_whenBuiltWithoutAStyle_thenItIsStandard() {
        // given / when
        let plain = MessageBoxView(model: .disabled) { _ in true }
        let compact = MessageBoxView(model: .disabled, isCompact: true) { _ in true }
        // then
        #expect(plain.style == .standard)
        #expect(compact.style == .standard)
    }

    @Test(arguments: [(ActivityFeedStyle.transcript, false), (.standard, false), (.transcript, true), (.standard, true)])
    func givenTaskDetailMount_whenStyled_thenOnlyATranscriptMountPaintsTheSurfaceComposer(style: ActivityFeedStyle, embedded: Bool) async throws {
        // given
        let size = CGSize(width: 1400, height: 800)
        let surface = try await token(TaskScreenStyle.Colors.surface, dark: false)
        let mock = TaskDetailViewModelMock.finished()
        let page = fixture(TaskDetailView(mock, isEmbedded: embedded, transcriptStyle: style)
            .environment(\.hfReduceMotionOverride, true), size: size, dark: false)
        defer { page.close() }
        await page.settle { page.element("Queue a message…") != nil || Self.editableField(in: page) != nil }
        var passes = 0
        await page.settle { passes += 1; return passes >= 30 }

        // when — a transcript composer is a run of --surface pixels beside the 696 point column's left edge; the glass one is not.
        let shot = Shot(page.host)
        let found = (150 ... 400)
.lazy
.compactMap { x in
            shot.composerBounds(surface: surface, columnX: CGFloat(x), rightX: CGFloat(x) + 680)
        }
.first

        // then
        if style == .transcript {
            let composer = try #require(found, "transcript mount (embedded \(embedded)) shows no surface composer")
            #expect(abs(composer.width - 696) <= 1.5, "width \(composer.width)")
        } else {
            #expect(found == nil, "standard mount (embedded \(embedded)) paints the surface composer \(String(describing: found))")
        }
    }

    @Test func givenParallelColumnAndWorkflowComposer_whenTheirBodiesAreReflected_thenEveryMessageBoxIsStandard() throws {
        // given
        let task = try #require(TaskInfo(.object([
            "task_id": .string("col"), "backend": .string("claude"), "status": .string("running"), "live_input": .bool(true)
        ])))
        let column = ParallelColumnModel(
            id: "col", task: task, title: "Column", subtitle: "Claude", isBusy: false, outcomeMessage: nil, showPrompt: false,
            prompt: nil, rows: [], activityRows: [], liveStep: nil, isLoading: false, summary: nil,
            onTapTakeover: {}, onTapOpenTask: {}
        )
        let workflow = WorkflowActivityMessageComposer(viewModel: WorkflowPreview.make(run: true))

        // when
        let parallel = Self.messageBoxStyles(in: ParallelColumnView(model: column).body)
        let nested = Self.messageBoxStyles(in: workflow.body)

        // then — the reflection reaches the composer in each body; an empty result would mean it asserts nothing.
        #expect(!parallel.isEmpty, "no MessageBoxView found in the Parallel column body")
        #expect(!nested.isEmpty, "no MessageBoxView found in the workflow composer body")
        #expect((parallel + nested).allSatisfy { $0 == .standard })
    }

    static func messageBoxStyles(in value: Any, depth: Int = 0) -> [MessageBoxStyle] {
        guard depth < 60 else { return [] }
        if let box = value as? MessageBoxView { return [box.style] }
        return Mirror(reflecting: value).children.flatMap { messageBoxStyles(in: $0.value, depth: depth + 1) }
    }
}
