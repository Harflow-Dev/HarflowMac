import MonitorCore
@testable import PbUI
import SwiftUI
import Testing

@Suite struct BackendStyleTests {
    
    @Test func givenAKnownBackend_whenReadingItsLetter_thenReturnsItsFixedLetter() {
        // given / when / then
        #expect(BackendStyle.letter("claude") == "C")
        #expect(BackendStyle.letter("codex") == "X")
        #expect(BackendStyle.letter("opencode") == "O")
        #expect(BackendStyle.letter("vibe") == "V")
    }
    
    @Test func givenAnUnknownBackend_whenReadingItsLetter_thenFallsBackToItsUppercasedFirstCharacter() {
        // given / when / then
        #expect(BackendStyle.letter("something") == "S")
    }
    
    @Test func givenEachKnownBackend_whenReadingItsHelpText_thenReturnsItsOneLineDescription() {
        // given / when / then
        #expect(BackendStyle.helpText("claude") == "Claude Code CLI")
        #expect(BackendStyle.helpText("codex") == "OpenAI Codex CLI")
        #expect(BackendStyle.helpText("vibe") == "Mistral Vibe CLI, using your configured model")
        #expect(BackendStyle.helpText("opencode") == "opencode CLI")
    }

    @Test func givenAnUnknownBackend_whenReadingItsHelpText_thenReturnsNil() {
        // given / when / then
        #expect(BackendStyle.helpText("mystery") == nil)
    }

    @Test func givenTheKnownBackendsList_whenReadingIt_thenContainsExactlyTheFourSupportedBackends() {
        // given / when / then
        #expect(BackendStyle.known == ["claude", "codex", "opencode", "vibe"])
    }
    
    @Test func givenEachKnownBackend_whenReadingItsColors_thenReturnsADistinctPair() {
        // given
        let pairs = BackendStyle.known.map(BackendStyle.colors)
        
        // when
        let uniqueBackgrounds = Set(pairs.map(\.0))
        
        // then — every known backend gets a visually distinct background.
        #expect(uniqueBackgrounds.count == BackendStyle.known.count)
    }
}

@Suite struct BackendDotStyleTests {

    @Test func givenEachKnownBackend_whenReadingItsDotEntry_thenItIsDistinctAndNotTheNeutralOne() {
        // given
        let entries = BackendStyle.known.map(BackendStyle.dotEntry)

        // when
        let names = Set(entries.map(\.name))

        // then
        #expect(names.count == BackendStyle.known.count)
        #expect(!names.contains(Palette.dotOther.name))
    }

    @Test func givenAnUnknownBackend_whenReadingItsDotEntry_thenItIsTheNeutralDotOther() {
        // given / when / then
        #expect(BackendStyle.dotEntry("mystery").name == "dot.other")
    }

    @Test func givenABackend_whenReadingItsDisplayName_thenTheFirstLetterIsCapitalised() {
        // given / when / then
        #expect(BackendStyle.displayName("vibe") == "Vibe")
        #expect(BackendStyle.displayName("mystery") == "Mystery")
        #expect(BackendStyle.displayName("") == "")
    }
}

@Suite struct StatusColorTests {
    
    @Test func givenRunning_whenReadingItsColor_thenReturnsRunningForeground() {
        #expect(StatusColor.of(.running) == .runningFG)
    }
    
    @Test func givenCompleted_whenReadingItsColor_thenReturnsDoneGreen() {
        #expect(StatusColor.of(.completed) == .doneGreen)
    }
    
    @Test func givenFailedOrTimedOut_whenReadingTheirColor_thenBothReturnFailedRed() {
        #expect(StatusColor.of(.failed) == .failedRed)
        #expect(StatusColor.of(.timedOut) == .failedRed)
    }
    
    @Test func givenCancelled_whenReadingItsColor_thenReturnsCancelledGray() {
        #expect(StatusColor.of(.cancelled) == .cancelledGray)
    }
    
    @Test func givenAnOtherStatus_whenReadingItsColor_thenReturnsSecondary() {
        #expect(StatusColor.of(.other("queued")) == .secondary)
    }

    @Test func givenEachBackend_whenAskingAboutATurnLimit_thenOnlyClaudeAndVibeSupportIt() {
        // given / when / then — mirrors polybridge's supports_turn_cap per backend.
        #expect(BackendStyle.supportsTurnLimit("claude"))
        #expect(BackendStyle.supportsTurnLimit("vibe"))
        #expect(!BackendStyle.supportsTurnLimit("codex"))
        #expect(!BackendStyle.supportsTurnLimit("opencode"))
        #expect(!BackendStyle.supportsTurnLimit("someday"))
    }
}
