@testable import PbUI
import SwiftUI
import Testing

/// MS-ACTIONS-3: the outcome line is red only when it starts with "Refused" — several genuine
/// refusal headlines do not, and must render in the normal colour.
@Suite struct OutcomeColorTests {
    
    @Test func givenAMessageStartingWithRefused_whenColored_thenItIsRed() {
        // given
        let message = "Refused: this session was taken over from another window."
        
        // when
        let color = OutcomeColor.of(message)
        
        // then
        #expect(color == .failedRed)
    }
    
    @Test func givenAKnownNonRefusedHeadline_whenColored_thenItIsNotRed() {
        // given — genuine refusal headlines that do not start with "Refused"
        // (`TakeoverRefusalCharacterizationTests`, MonitorCoreTests).
        let headlines = [
            "unknown_task", "closed", "settled", "exited", "not_live_input", "owner_not_alive",
            "Queued; folded into the current turn or sent after it."
        ]
        
        // when / then
        for headline in headlines {
            #expect(OutcomeColor.of(headline) == .secondary)
        }
    }
}
