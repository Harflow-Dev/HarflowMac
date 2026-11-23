import HfUI
@testable import SettingsFeature
import Testing

struct QualificationGlyphTests {
    @Test func givenEachQualificationState_whenMapped_thenGlyphFollowsTheDesign() {
        // given
        let expected: [HarnessQualificationModel.State: RowGlyph?] = [
            .ready: .done,
            .failed: .failed,
            .failedAtRuntime: .failed,
            .cancelled: .cancelled,
            .binaryChanged: .attention,
            .unsupported: .attention,
            .notChecked: nil,
            .checking: nil,
            .unavailable: nil
        ]
        // when / then
        #expect(Set(expected.keys) == Set(HarnessQualificationModel.State.allCases))
        for (state, glyph) in expected {
            #expect(QualificationGlyph.for(state) == glyph)
        }
    }

    @Test func givenCancelledAndUnavailableGlyphs_whenMapped_thenTheyHaveTheirOwnLabels() {
        // given / when / then
        #expect(RowGlyph.cancelled.status == .cancelled)
        #expect(RowGlyph.cancelled.accessibilityLabel == "Cancelled")
        #expect(RowGlyph.unavailable.status == nil)
        #expect(RowGlyph.unavailable.unavailableSymbol == "xmark")
        #expect(RowGlyph.unavailable.accessibilityLabel == "Not found")
    }

    @Test func givenTheNativeSet_whenAsked_thenOnlyClaudeCodexAndVibeAreNative() {
        // given / when / then
        #expect(["claude", "codex", "vibe"].allSatisfy(NativeQualification.isNative))
        #expect(!["opencode", "antigravity", "cursor"].contains(where: NativeQualification.isNative))
    }
}
