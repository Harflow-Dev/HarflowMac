import Foundation
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

@Suite struct ToolGroupWordingTests {
    typealias Fixture = ActivityFixture

    private func summary(_ rows: [ConversationTimelineRow]) -> String? {
        ActivityRowsBuilder.build(from: rows).first?.group?.summary
    }

    // MARK: - Read

    @Test func givenReadsOfDistinctFiles_whenSummarised_thenItCountsFiles() {
        #expect(summary([Fixture.tool(1, path: "/a"), Fixture.tool(2, path: "/b"), Fixture.tool(3, path: "/c")]) == "Read 3 files")
    }

    @Test func givenTheSameFileReadTwice_whenSummarised_thenItCountsDistinctPaths() {
        #expect(summary([Fixture.tool(1, path: "/a"), Fixture.tool(2, path: "/a"), Fixture.tool(3, path: "/b")]) == "Read 2 files")
    }

    @Test func givenReadsWithNoKnownPath_whenSummarised_thenItCountsReadsNotFiles() {
        #expect(summary([Fixture.tool(1), Fixture.tool(2)]) == "2 reads")
    }

    @Test func givenASingleRead_whenSummarised_thenSingularForms() {
        #expect(summary([Fixture.tool(1, path: "/a")]) == "Read 1 file")
        #expect(summary([Fixture.tool(1)]) == "1 read")
    }

    @Test func givenFailedReads_whenSummarised_thenTheFailureCountIsShown() {
        // given
        let rows = [Fixture.tool(1, path: "/a"), Fixture.tool(2, path: "/b", ok: false), Fixture.tool(3, path: "/c", ok: false)]
        // when / then
        #expect(summary(rows) == "Read 3 files · 2 failed")
    }

    @Test func givenAPendingRead_whenSummarised_thenItIsNotCountedAsFailed() {
        #expect(summary([Fixture.tool(1, path: "/a", resolved: false)]) == "Read 1 file")
    }

    // MARK: - Search, shell, other

    @Test func givenSearches_whenSummarised_thenItCountsTimes() {
        #expect(summary([Fixture.tool(1, category: "search"), Fixture.tool(2, category: "search")]) == "Searched 2 times")
        #expect(summary([Fixture.tool(1, category: "search")]) == "Searched 1 time")
    }

    @Test func givenShellCommands_whenSummarised_thenItCountsCommands() {
        #expect(summary([Fixture.tool(1, category: "shell"), Fixture.tool(2, category: "shell"), Fixture.tool(3, category: "shell")]) == "Ran 3 commands")
        #expect(summary([Fixture.tool(1, category: "shell")]) == "Ran 1 command")
    }

    @Test func givenMcpWebAndUnknownCategories_whenSummarised_thenItCountsTools() {
        #expect(summary([Fixture.tool(1, category: "mcp"), Fixture.tool(2, category: "web"), Fixture.tool(3, category: "other")]) == "Used 3 tools")
        #expect(summary([Fixture.tool(1, category: "mcp")]) == "Used 1 tool")
    }

    // MARK: - Search subtitle

    @Test func givenSearchInputsWithPatternOrQuery_whenBuilt_thenTheSubtitleListsTheDistinctTerms() {
        // given
        let rows = [
            Fixture.tool(1, category: "search", input: #"{"pattern":"KeychainStore"}"#),
            Fixture.tool(2, category: "search", input: #"{"query":"warm the store"}"#),
            Fixture.tool(3, category: "search", input: #"{"pattern":"KeychainStore"}"#)
        ]
        // when
        let subtitle = ActivityRowsBuilder.build(from: rows)[0].group?.subtitle
        // then
        #expect(subtitle == "KeychainStore, warm the store")
    }

    @Test func givenSearchInputsThatDoNotParse_whenBuilt_thenThereIsNoSubtitle() {
        // given — a plain-text preview, a truncated JSON preview, and JSON with neither key.
        let rows = [
            Fixture.tool(1, category: "search", input: "grep -rn foo"),
            Fixture.tool(2, category: "search", input: #"{"pattern":"abc"#),
            Fixture.tool(3, category: "search", input: #"{"glob":"*.swift"}"#)
        ]
        // when / then
        #expect(ActivityRowsBuilder.build(from: rows)[0].group?.subtitle == nil)
    }

    @Test func givenMoreThanThreeTerms_whenBuilt_thenTheSubtitleSaysHowManyMore() {
        // given
        let rows = (1 ... 5).map { Fixture.tool($0, category: "search", input: #"{"pattern":"term\#($0)"}"#) }
        // when / then
        #expect(ActivityRowsBuilder.build(from: rows)[0].group?.subtitle == "term1, term2, term3 +2 more")
    }

    @Test func givenANonSearchGroup_whenBuilt_thenThereIsNoSubtitle() {
        #expect(ActivityRowsBuilder.build(from: [Fixture.tool(1, path: "/a", input: #"{"pattern":"x"}"#)])[0].group?.subtitle == nil)
    }

    // MARK: - Pills

    @Test func givenMoreThanNineFiles_whenBuilt_thenPillsAreCappedWithAnOverflowCount() {
        // given
        let rows = (1 ... 12).map { Fixture.tool($0, path: "/src/File\($0).swift") }
        // when
        let group = ActivityRowsBuilder.build(from: rows)[0].group
        // then
        #expect(group?.pillNames.count == 9)
        #expect(group?.pillNames.first == "File1.swift")
        #expect(group?.overflowCount == 3)
    }

    @Test func givenANonReadGroup_whenBuilt_thenThereAreNoPills() {
        #expect(ActivityRowsBuilder.build(from: [Fixture.tool(1, category: "shell", path: "/a")])[0].group?.pillNames == [])
    }

    // MARK: - Backend-shaped streams

    @Test func givenAClaudeLikeStream_whenBuilt_thenReadsSearchesAndCommandsFoldSeparately() {
        // given — Read, Read, Grep, Bash, Bash with prose between them.
        let rows = [
            Fixture.text(1),
            Fixture.tool(2, path: "/a.swift", tool: "Read"), Fixture.tool(3, path: "/b.swift", tool: "Read"),
            Fixture.tool(4, category: "search", input: #"{"pattern":"foo"}"#, tool: "Grep"),
            Fixture.tool(5, category: "shell", command: "swift build", tool: "Bash"),
            Fixture.tool(6, category: "shell", command: "swift test", tool: "Bash")
        ]
        // when
        let summaries = ActivityRowsBuilder.build(from: rows).compactMap { $0.group?.summary }
        // then
        #expect(summaries == ["Read 2 files", "Searched 1 time", "Ran 2 commands"])
    }

    @Test func givenACodexLikeStream_whenBuilt_thenShellMcpAndEditAreHandledHonestly() {
        // given — codex emits shell commands, mcp calls and file_change edits (with a path, no read category).
        let rows = [
            Fixture.tool(1, category: "shell", command: "rg foo", tool: "shell"),
            Fixture.tool(2, category: "shell", command: "sed -n 1,20p a.swift", tool: "shell"),
            Fixture.tool(3, category: "mcp", tool: "mocktail_list"),
            Fixture.tool(4, category: "edit", path: "/a.swift", tool: "file_change"),
            Fixture.tool(5, category: "shell", command: "swift test", tool: "shell")
        ]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then — no read or search claim is invented from shell commands.
        #expect(result.map { $0.group?.summary ?? "edit row" } == ["Ran 2 commands", "Used 1 tool", "edit row", "Ran 1 command"])
    }
}
