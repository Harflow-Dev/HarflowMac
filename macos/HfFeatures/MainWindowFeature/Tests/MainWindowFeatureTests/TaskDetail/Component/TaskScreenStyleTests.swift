//
//  TaskScreenStyleTests.swift
//  MainWindowFeatureTests
//

@testable import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskScreenStyleTests

@MainActor
struct TaskScreenStyleTests {
    @Test func givenTheTranscriptRule_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(TaskScreenStyle.designCommit == "3643d08")
        #expect(TaskScreenStyle.Transcript.maxWidth == 760)
        #expect(TaskScreenStyle.Transcript.paddingTop == 24)
        #expect(TaskScreenStyle.Transcript.paddingHorizontal == 32)
        #expect(TaskScreenStyle.Transcript.paddingBottom == 16)
        #expect(TaskScreenStyle.Transcript.gap == 16)
    }

    @Test func givenTheComposerRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(TaskScreenStyle.Composer.cornerRadius == 18)
        #expect(TaskScreenStyle.Composer.paddingTop == 12)
        #expect(TaskScreenStyle.Composer.paddingTrailing == 12)
        #expect(TaskScreenStyle.Composer.paddingBottom == 8)
        #expect(TaskScreenStyle.Composer.paddingLeading == 16)
        #expect(TaskScreenStyle.Composer.inputMinHeight == 28)
        #expect(TaskScreenStyle.Composer.inputRows == 2)
        #expect(TaskScreenStyle.Composer.sendSize == 32)
        #expect(TaskScreenStyle.Composer.shadow.map(\.offsetY) == [1, 4])
        #expect(TaskScreenStyle.Composer.shadow.map(\.blur) == [2, 16])
        #expect(TaskScreenStyle.ComposerWrapper.paddingTop == 8)
        #expect(TaskScreenStyle.ComposerWrapper.paddingHorizontal == 32)
        #expect(TaskScreenStyle.ComposerWrapper.paddingBottom == 24)
    }

    @Test func givenTheTranscriptRows_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(TaskScreenStyle.UserBubble.maxWidthFraction == 0.8)
        #expect(TaskScreenStyle.UserBubble.paddingVertical == 10)
        #expect(TaskScreenStyle.UserBubble.paddingHorizontal == 14)
        #expect(TaskScreenStyle.AgentProse.text == .init(size: 14, lineHeight: 22))
        #expect(TaskScreenStyle.InlineCode.fontSize == 12.5)
        #expect(TaskScreenStyle.TurnSeparator.text == .init(size: 12, lineHeight: 16))
        #expect(TaskScreenStyle.Working.fontSize == 13)
        #expect(TaskScreenStyle.ToolHead.minHeight == 28)
        #expect(TaskScreenStyle.ToolBody.marginLeading == 22)
        #expect(TaskScreenStyle.ToolBody.maxHeight == 220)
    }

    @Test func givenEveryToken_whenComparedToPalette_thenAPaletteMatchIsExactAndOthersHaveNone() throws {
        // given
        let palette = Dictionary(uniqueKeysWithValues: Palette.all.map { ($0.name, $0) })

        // when / then
        for token in TaskScreenStyle.Colors.all {
            if let name = token.paletteName {
                let entry = try #require(palette[name])
                #expect(entry.light == token.light && entry.dark == token.dark, "\(token.cssName) vs \(name)")
            } else {
                #expect(
                    !palette.values.contains { $0.light == token.light && $0.dark == token.dark },
                    "\(token.cssName) equals a Palette entry but is not mapped to it"
                )
            }
        }
    }

    /// `tokens.css` at 3643d08, light then dark.
    private static let pinnedTokens: [(cssName: String, light: UInt32, dark: UInt32)] = [
        ("--surface", 0xFFFFFF, 0x343437), ("--surface-hover", 0xEBEBEA, 0x3B3B3E),
        ("--surface-active", 0xE3E3E2, 0x444448), ("--surface-sunken", 0xF4F4F3, 0x262628),
        ("--border", 0xE2E2E0, 0x404044), ("--text", 0x1D1D1F, 0xECECEE),
        ("--text-secondary", 0x56575C, 0xB7B7BC), ("--text-tertiary", 0x5F6065, 0xADADB3),
        ("--accent", 0x2B63D9, 0x7AA5FF), ("--accent-solid", 0x2B63D9, 0x3D6FDC),
        ("--accent-solid-hover", 0x2455BD, 0x3462C9), ("--accent-subtle", 0xE7EEFC, 0x2F3A52),
        ("--on-accent", 0xFFFFFF, 0xFFFFFF)
    ]

    @Test func givenTheDesignTokens_whenComparedToTheMap_thenEveryTokenIsPresentWithExactValues() {
        // given
        let mapped = Dictionary(uniqueKeysWithValues: TaskScreenStyle.Colors.all.map { ($0.cssName, $0) })

        // when / then
        #expect(Self.pinnedTokens.count == 13)
        #expect(TaskScreenStyle.Colors.all.count == Self.pinnedTokens.count)
        #expect(Set(mapped.keys) == Set(Self.pinnedTokens.map(\.cssName)))
        for pinned in Self.pinnedTokens {
            #expect(mapped[pinned.cssName]?.light == pinned.light, "\(pinned.cssName) light")
            #expect(mapped[pinned.cssName]?.dark == pinned.dark, "\(pinned.cssName) dark")
        }
    }

    @Test func givenTheComposerShadow_whenRead_thenAllFourValuesMatchTheDesign() {
        // given / when
        let layers = TaskScreenStyle.Composer.shadow

        // then — `--shadow-composer`: light 0.04 / 0.06, dark 0.3 / 0.25
        #expect(layers.map(\.lightOpacity) == [0.04, 0.06])
        #expect(layers.map(\.darkOpacity) == [0.3, 0.25])
    }

    @Test func givenTheRemainingRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(TaskScreenStyle.Composer.gap == 8)
        #expect(TaskScreenStyle.Composer.barGap == 6)
        #expect(TaskScreenStyle.ToolHead.cornerRadius == 8)
        #expect(TaskScreenStyle.ToolHead.gap == 8)
        #expect(TaskScreenStyle.ToolHead.paddingVertical == 3)
        #expect(TaskScreenStyle.ToolHead.paddingHorizontal == 6)
        #expect(TaskScreenStyle.ToolHead.horizontalBleed == 6)
        #expect(TaskScreenStyle.ToolHead.hoverCornerRadius == 6)
        #expect(TaskScreenStyle.ToolHead.text == .init(size: 13, lineHeight: 18))
        #expect(TaskScreenStyle.ToolHead.summaryCodeSize == 12)
        #expect(TaskScreenStyle.ToolHead.metaSize == 12)
        #expect(TaskScreenStyle.ToolBody.marginTop == 4)
        #expect(TaskScreenStyle.ToolBody.marginBottom == 2)
        #expect(TaskScreenStyle.ToolBody.cornerRadius == 8)
        #expect(TaskScreenStyle.ToolBody.paddingVertical == 10)
        #expect(TaskScreenStyle.ToolBody.paddingHorizontal == 12)
        #expect(TaskScreenStyle.ToolBody.text == .init(size: 12, lineHeight: 18))
    }

    @Test func givenTheAddedTokens_whenListed_thenOnlyOnAccentReusesThePalette() {
        // given / when
        let reused = TaskScreenStyle.Colors.all.filter { $0.paletteName != nil }.map(\.cssName)

        // then
        #expect(reused == ["--on-accent"])
        #expect(!TaskScreenStyle.addedTokens.contains { $0.cssName == "--on-accent" })
    }
}
