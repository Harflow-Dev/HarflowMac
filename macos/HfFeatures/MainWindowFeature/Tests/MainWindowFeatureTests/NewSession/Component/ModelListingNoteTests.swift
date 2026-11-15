import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct ModelListingNoteTests {

    private let takesModel = BackendControls(facts: BackendControlFixtures.claude)
    private let takesNoModel = BackendControls(facts: BackendControlFixtures.vibeNotReady)

    private func note(
        _ phase: ModelListingPhase, harness: String = "codex", controls: BackendControls? = nil, catalogReady: Bool = true,
        agentNotFound: Bool = false
    ) -> ModelListingNote? {
        ModelListingNote.make(
            phase: phase, harness: harness, controls: controls ?? takesModel, catalogReady: catalogReady, agentNotFound: agentNotFound
        )
    }

    private func rows(_ count: Int) -> [ModelOption] { (0 ..< count).map { ModelOption(value: "m\($0)", label: "M\($0)") } }

    private func loaded(
        _ state: ModelListingState, source: BackendModelListing.Source? = nil, rows count: Int = 0, truncated: Bool = false, dropped: Int = 0
    ) -> ModelListingPhase {
        .loaded(ModelListing(state: state, source: source, options: rows(count), truncated: truncated, droppedCount: dropped))
    }

    // MARK: - Precedence

    @Test func givenAHarnessThatTakesNoModel_whenTheCatalogIsReady_thenOnlyThePerControlMessageShows() {
        // given
        let phases: [ModelListingPhase] = [.idle, .loading, loaded(.unavailable(.timeout)), loaded(.available, rows: 2)]

        // then
        for phase in phases {
            #expect(note(phase, controls: takesNoModel) == ModelListingNote(
                text: "Model selection isn't available for this harness.", showsRetry: false
            ))
        }
    }

    @Test func givenAHarnessThatTakesNoModel_whenTheCatalogIsNotReady_thenThereIsNoNote() {
        #expect(note(.loading, controls: takesNoModel, catalogReady: false) == nil)
    }

    @Test func givenTheHarnessIsNotFound_whenAnyListingIsLoaded_thenTheModelNoteStaysSilent() {
        #expect(note(.loading, agentNotFound: true) == nil)
        #expect(note(loaded(.notInstalled), agentNotFound: true) == nil)
        #expect(note(loaded(.unavailable(.timeout)), agentNotFound: true) == nil)
    }

    @Test func givenNoListingIsRead_whenIdle_thenThereIsNoNote() {
        #expect(note(.idle) == nil)
    }

    // MARK: - States

    @Test func givenALoadingListing_whenNoted_thenItSaysSoWithoutRetry() {
        #expect(note(.loading) == ModelListingNote(text: "Loading suggested models… You can still type a model name.", showsRetry: false))
    }

    @Test func givenNotInstalledInTheListing_whenNoted_thenItNamesTheHarnessByItsDisplayName() {
        #expect(note(loaded(.notInstalled), harness: "antigravity") == ModelListingNote(
            text: "Antigravity wasn't found on your PATH — starting this harness may fail.", showsRetry: false
        ))
    }

    @Test(arguments: [
        (BackendModelListing.Reason.timeout, "Codex took too long to list its models."),
        (.exitNonzero, "Codex stopped with an error while listing its models."),
        (.authRequired, "Codex needs you to sign in before it can list models."),
        (.unparseable, "Codex's model list couldn't be read."),
        (.outputCeiling, "Codex's model list was too long to read."),
        (.spawnFailed, "Codex couldn't be started to list its models.")
    ])
    func givenAnUnavailableListing_whenNoted_thenTheReasonSentenceNamesTheHarnessAndRetryIsOffered(
        _ reason: BackendModelListing.Reason, _ sentence: String
    ) {
        #expect(note(loaded(.unavailable(reason))) == ModelListingNote(
            text: "Suggested models aren't available. \(sentence) You can still type a model name.", showsRetry: true
        ))
    }

    @Test(arguments: [
        (BackendModelListing.Source.harnessCache as BackendModelListing.Source?, "Codex's model cache wasn't found."),
        (.configAliases, "Codex's model configuration wasn't found."),
        (.cliOutput, "Codex's model list wasn't found."),
        (.unrecognized("future"), "Codex's model list wasn't found."),
        (nil, "Codex's model list wasn't found.")
    ])
    func givenSourceMissing_whenNoted_thenTheSentenceFollowsTheSource(_ source: BackendModelListing.Source?, _ sentence: String) {
        #expect(note(loaded(.unavailable(.sourceMissing), source: source))?.text
            == "Suggested models aren't available. \(sentence) You can still type a model name.")
    }

    @Test(arguments: [BackendModelListing.Reason?.none, .some(.unrecognized("future_reason"))])
    func givenAnUnknownOrMissingReason_whenNoted_thenTheReasonSentenceIsDropped(_ reason: BackendModelListing.Reason?) {
        #expect(note(loaded(.unavailable(reason))) == ModelListingNote(
            text: "Suggested models aren't available. You can still type a model name.", showsRetry: true
        ))
    }

    @Test func givenAnAvailableListingWithNoRows_whenNoted_thenItSaysTheHarnessListsNone() {
        #expect(note(loaded(.available)) == ModelListingNote(text: "Codex lists no models. You can still type a model name.", showsRetry: false))
    }

    @Test func givenATruncatedListing_whenNoted_thenItCountsTheRowsReturned() {
        #expect(note(loaded(.available, rows: 400, truncated: true), harness: "opencode") == ModelListingNote(
            text: "Showing the first 400 models Opencode listed. You can type a model name that isn't shown.", showsRetry: false
        ))
    }

    @Test func givenATruncatedListingWithDroppedRows_whenNoted_thenTheDroppedSentenceIsAppended() {
        #expect(note(loaded(.available, rows: 12, truncated: true, dropped: 3), harness: "opencode")?.text
            == "Showing the first 12 models Opencode listed. You can type a model name that isn't shown. "
            + "3 entries were invalid or repeated and were left out.")
        #expect(note(loaded(.available, rows: 12, truncated: true, dropped: 1), harness: "opencode")?.text
            == "Showing the first 12 models Opencode listed. You can type a model name that isn't shown. "
            + "1 entry was invalid or repeated and was left out.")
    }

    @Test func givenDroppedRowsAlone_whenNoted_thenOnlyTheDroppedSentenceShows() {
        #expect(note(loaded(.available, rows: 5, dropped: 2))?.text == "2 entries were invalid or repeated and were left out.")
        #expect(note(loaded(.available, rows: 5, dropped: 1))?.text == "1 entry was invalid or repeated and was left out.")
    }

    @Test func givenACompleteAvailableListing_whenNoted_thenThereIsNoNote() {
        #expect(note(loaded(.available, rows: 5)) == nil)
    }

    @Test func givenUnsupported_whenNoted_thenItIsTheHarnessLevelSentence() {
        #expect(note(loaded(.unsupported)) == ModelListingNote(
            text: "Suggested models aren't available for this harness. You can still type a model name.", showsRetry: false
        ))
    }

    @Test(arguments: [ModelListingState.unrecognized("future_state"), .unreadable])
    func givenAnUnknownStateOrAnUnreadableListing_whenNoted_thenItIsTheGenericSentenceWithoutRetry(_ state: ModelListingState) {
        #expect(note(loaded(state)) == ModelListingNote(
            text: "Suggested models aren't available. You can still type a model name.", showsRetry: false
        ))
    }

    @Test func givenTheHarnessIsRenamedByDisplayName_whenNoted_thenNoteUsesItInsteadOfTheId() {
        #expect(note(loaded(.available), harness: "vibe")?.text == "Vibe lists no models. You can still type a model name.")
    }
}
