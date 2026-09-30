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
}
