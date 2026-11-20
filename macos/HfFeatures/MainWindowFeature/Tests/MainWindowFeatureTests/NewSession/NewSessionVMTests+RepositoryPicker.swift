import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import Testing

// MARK: - Repository path validation

@MainActor
extension NewSessionVMTests {
    @Test(arguments: ["", " \n\t"])
    func givenAnEmptyRepo_whenCommitted_thenItRemainsNeutral(input: String) {
        // given — the message is valid, leaving only the empty repo to block starting.
        let (sut, useCase, _, _) = makeSUT()
        sut.didChangeMessage("do the thing")
        sut.didChangeRepo(input)

        // when
        sut.didCommitRepo()

        // then
        #expect(sut.repo == input && sut.isRepoEmpty)
        #expect(sut.canStart == false && sut.repoError == nil)
        verify(useCase).existingDirectories(among: .any).called(0)
    }

    // MARK: - Repo path validation (exact copy)

    @Test func givenARelativeOrMissingPath_whenStarted_thenTheExactValidationTextIsShown() async {
        // given
        let (sut, useCase, routing, _) = makeSUT()
        defer { withExtendedLifetime(routing) {} }
        given(useCase).resolvedRepoPath(.any).willReturn(nil)
        sut.didChangeRepo("relative/path")
        sut.didChangeMessage("do the thing")

        // when
        await waitUntil { sut.canStart }
        sut.didTapStart()

        // then
        #expect(sut.repoError == "Choose an existing folder.")
        #expect(sut.errorText == nil && sut.validationMessages.isEmpty && !sut.canStart)
        verify(useCase).run(.any, runtime: .any).called(0)
    }

    @Test func givenACommittedFolderDisappears_whenStarted_thenTheFreshProbeBlocksLaunch() async {
        // given
        let (sut, useCase, routing, _) = makeSUT(catalog: catalog([("claude", true)]))
        defer { withExtendedLifetime(routing) {} }
        let input = "/fixture/repository with spaces "
        given(useCase).resolvedRepoPath(.value(input)).willReturn(nil)
        sut.didChangeRepo(input)
        sut.didChangeMessage("Inspect the repository")
        sut.didCommitRepo()
        await sut.repoCheckTask?.value
        await waitUntil { sut.canStart }

        // when
        #expect(sut.canStart)
        sut.didTapStart()
        sut.didTapStart()

        // then
        verify(useCase).existingDirectories(among: .value([input])).called(1)
        verify(useCase).resolvedRepoPath(.value(input)).called(1)
        verify(useCase).run(.any, runtime: .any).called(0)
        #expect(sut.repoError == "Choose an existing folder." && !sut.canStart)
        sut.didChangeRepo("/fixture/other")
        #expect(sut.repoError == nil)
    }

    @Test func givenAPrecomposedPath_whenEditedToEquivalentDecomposedText_thenCheckReceivesTheNewPathBytes() async throws {
        // given
        let useCase = GatedRecentsUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        let precomposed = "/fixture/caf\u{e9}"
        let decomposed = "/fixture/cafe\u{301}"
        sut.didAppear()
        defer { sut.didDisappear() }
        sut.didChangeRepo(precomposed)

        // when
        sut.didChangeRepo(decomposed)
        sut.didCommitRepo()
        await waitUntil { useCase.requests.count == 1 }
        let checked = try #require(useCase.requests.first?.paths.first)
        useCase.answer(0, [checked])
        await sut.repoCheckTask?.value

        // then
        #expect(Array(sut.repo.utf8) == Array(decomposed.utf8))
        #expect(Array(checked.utf8) == Array(decomposed.utf8))
    }

    @Test func givenAnUnansweredCommit_whenEditedAndCommittedAgain_thenTheOldAnswerCannotClearTheNewError() async throws {
        // given
        let useCase = GatedRecentsUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        sut.didAppear()
        defer { sut.didDisappear() }
        sut.didChangeRepo("/fixture/old")
        sut.didCommitRepo()
        await waitUntil { useCase.requests.count == 1 }
        try #require(useCase.requests.count == 1)
        let oldCheck = sut.repoCheckTask

        // when
        sut.didChangeRepo("/fixture/current")
        sut.didCommitRepo()
        sut.didCommitRepo()
        await waitUntil { useCase.requests.count >= 2 }
        let currentCheck = sut.repoCheckTask
        let paths = useCase.requests.map(\.paths)
        for index in paths.indices.reversed() {
            useCase.answer(index, index == 0 ? ["/fixture/old"] : [])
            if index == 1 { await currentCheck?.value }
        }
        await oldCheck?.value

        // then
        #expect(paths == [["/fixture/old"], ["/fixture/current"]])
        #expect(sut.repoError == "Choose an existing folder.")
    }

    @Test func givenAnUnansweredCommit_whenTheSameRecentPathIsSelected_thenItsLateMissingAnswerIsIgnored() async throws {
        // given
        let useCase = GatedRecentsUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        let path = "/fixture/same-path"
        sut.didAppear()
        defer { sut.didDisappear() }
        sut.didChangeRepo(path)
        sut.didCommitRepo()
        await waitUntil { useCase.requests.count == 1 }
        try #require(useCase.requests.count == 1)
        let oldCheck = sut.repoCheckTask

        // when
        sut.didTapRecentRepo(path)
        useCase.answer(0, [])
        await oldCheck?.value

        // then
        #expect(Array(sut.repo.utf8) == Array(path.utf8))
        #expect(!sut.hasUncommittedRepoEdit)
        #expect(sut.repoError == nil && sut.repoCheckTask == nil)
        #expect(useCase.requests.map(\.paths) == [[path]])
    }

    @Test func givenAnUnansweredCommit_whenStartFindsTheFolderMissing_thenItsLateAnswerCannotClearTheError() async throws {
        // given
        let useCase = GatedRecentsUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        let path = "/fixture/disappeared"
        sut.didAppear()
        defer { sut.didDisappear() }
        sut.didChangeRepo(path)
        sut.didChangeMessage("Inspect the repository")
        sut.didCommitRepo()
        await waitUntil { useCase.requests.count == 1 && sut.canStart }
        try #require(useCase.requests.count == 1)
        let check = sut.repoCheckTask
        useCase.missingAtStart.insert(path)

        // when
        #expect(sut.canStart)
        sut.didTapStart()
        useCase.answer(0, [path])
        await check?.value

        // then
        #expect(sut.repoError == "Choose an existing folder.")
        #expect(sut.repoCheckTask == nil && !sut.canStart && sut.composerState == .editable)
    }

    @Test func givenAnUnansweredCommit_whenTheComposerDisappears_thenTheAnswerAndLaterCommitCallbacksAreIgnored() async throws {
        // given
        let useCase = GatedRecentsUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        sut.didAppear()
        sut.didChangeRepo("/fixture/missing")
        sut.didCommitRepo()
        await waitUntil { useCase.requests.count == 1 }
        try #require(useCase.requests.count == 1)
        let check = sut.repoCheckTask

        // when
        sut.didDisappear()
        sut.didCommitRepo()
        useCase.answer(0, [])
        await check?.value

        // then
        #expect(sut.repoError == nil && sut.repoCheckTask == nil)
        #expect(useCase.requests.count == 1)
    }
}
