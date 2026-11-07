import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskChangesTextTests

struct TaskChangesTextTests {
    private static let secret = "SECRET-DIFF-TOKEN-4711"

    private static func chunk(_ value: JSONValue) throws -> TaskChangesTextChunk { try #require(Doc.decodeChunk(value)) }

    private static func b64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    // MARK: Chunk decoding

    @Test func givenSyntheticUtf8Chunk_whenDecoded_thenBytesAreTheExactUtf8AndEncodingIsUtf8() throws {
        // given
        let text = "+caf\u{E9} \u{1F642}\n"
        // when
        let decoded = try Self.chunk(Doc.chunk(text: text))
        // then
        #expect(decoded.bytes == Data(text.utf8) && decoded.encoding == .utf8 && decoded.offset == 0)
        #expect(decoded.totalBytes == text.utf8.count && !decoded.hasMore && decoded.nextCursor == nil)
    }

    @Test func givenSyntheticNonUtf8Chunk_whenDecoded_thenBase64BytesAreKeptExactly() throws {
        // given
        let bytes: [UInt8] = [0x2B, 0xFF, 0xFE, 0x00, 0x80, 0x0A]
        // when
        let decoded = try Self.chunk(Doc.chunk(text: nil, textB64: Self.b64(bytes)))
        // then
        #expect(decoded.bytes == Data(bytes) && decoded.encoding == .base64)
        #expect(String(data: decoded.bytes, encoding: .utf8) == nil)
    }

    @Test(arguments: ["both", "neither", "bad-base64", "text-is-number"])
    func givenSyntheticPayloadKeys_whenNotExactlyOneValid_thenChunkIsRejected(mode: String) {
        // given
        var chunk = Doc.chunk(text: "x")
        switch mode {
        case "both": chunk = chunk.setting(["text_b64"], to: .string(Self.b64([0x78])))
        case "neither": chunk = chunk.setting(["text"], to: .null)
        case "bad-base64": chunk = Doc.chunk(text: nil, textB64: "***").setting(["returned_bytes"], to: .number(0))
        default: chunk = chunk.setting(["text"], to: .number(1))
        }
        // when / then
        #expect(Doc.decodeChunk(chunk) == nil)
    }

    @Test func givenSyntheticChunkWithAMissingPayloadKey_whenDecoded_thenItIsRejected() {
        // given / when / then
        #expect(Doc.decodeChunk(Doc.chunk(text: "x").setting(["text_b64"], to: nil)) == nil)
        #expect(Doc.decodeChunk(Doc.chunk(text: "x").setting(["text"], to: nil)) == nil)
    }

    @Test(arguments: [
        ("returned-mismatch", "returned_bytes", 5), ("offset-overruns-total", "offset", 3), ("total-too-small", "total_bytes", 3)
    ])
    func givenSyntheticChunkCounts_whenInconsistent_thenItIsRejected(_: String, key: String, value: Int) {
        // given
        let chunk = Doc.chunk(text: "abcd").setting([.key(key)], to: .number(Double(value)))
        // when / then
        #expect(Doc.decodeChunk(chunk) == nil)
    }

    @Test func givenSyntheticHasMoreThatDisagreesWithTheOffsets_whenDecoded_thenItIsRejected() {
        // given
        let claimsMore = Doc.chunk(text: "ab", total: 2).setting(["has_more"], to: .bool(true)).setting(["next_cursor"], to: .string("c"))
        let claimsDone = Doc.chunk(text: "ab", total: 5, cursor: "c").setting(["has_more"], to: .bool(false)).setting(["next_cursor"], to: .null)
        // when / then
        #expect(Doc.decodeChunk(claimsMore) == nil)
        #expect(Doc.decodeChunk(claimsDone) == nil)
    }

    @Test func givenSyntheticChunkWithMoreButEmptyPayload_whenDecoded_thenNoProgressChunkIsRejected() {
        // given
        let chunk = Doc.chunk(text: "", offset: 0, total: 10, cursor: "c")
        // when / then
        #expect(Doc.decodeChunk(chunk) == nil)
    }

    @Test func givenSyntheticChunkWhoseCursorDisagreesWithHasMore_whenDecoded_thenItIsRejected() {
        // given
        let moreWithoutCursor = Doc.chunk(text: "ab", total: 5, cursor: "c").setting(["next_cursor"], to: .null)
        let cursorWithoutMore = Doc.chunk(text: "ab", total: 2).setting(["next_cursor"], to: .string("c"))
        // when / then
        #expect(Doc.decodeChunk(moreWithoutCursor) == nil)
        #expect(Doc.decodeChunk(cursorWithoutMore) == nil)
    }

    @Test func givenSyntheticRowWithoutStoredText_whenDecoded_thenEmptyTextKeepsTheContentState() throws {
        // given
        let chunk = Doc.chunk(text: "", total: 0, status: "untracked", content: Doc.content(state: "not_captured", reason: "untracked", bytes: 0))
        // when
        let decoded = try Self.chunk(chunk)
        // then
        #expect(decoded.bytes.isEmpty && decoded.totalBytes == 0 && !decoded.hasMore)
        #expect(decoded.content.state == .notCaptured && decoded.content.reason == "untracked" && decoded.status == .untracked)
    }

    @Test(arguments: [65_536, 65_537])
    func givenSyntheticTotalAtAndOverThe64KiBCap_whenDecoded_thenOnlyTheCapIsAccepted(total: Int) {
        // given
        let chunk = Doc.chunk(text: "abcd", total: total, cursor: "c")
        // when / then
        #expect((Doc.decodeChunk(chunk) != nil) == (total <= TaskChangesLimits.maxTextBytes))
    }

    @Test(arguments: ["both", "neither"])
    func givenSyntheticChunkPathPair_whenBothOrNeither_thenItIsRejected(mode: String) {
        // given
        let chunk = mode == "both" ? Doc.chunk(path: "a", pathB64: Self.b64([0x61])) : Doc.chunk(path: nil)
        // when / then
        #expect(Doc.decodeChunk(chunk) == nil)
    }

    @Test func givenSyntheticListingDocument_whenDecodedAsChunk_thenItIsRejected() {
        // given
        let chunk = Doc.chunk(text: "x").setting(["mode"], to: .string("list"))
        // when / then
        #expect(Doc.decodeChunk(chunk) == nil)
    }

    @Test func givenSyntheticUnknownStatusScopeAndContent_whenChunkDecoded_thenValuesAreKeptVerbatim() throws {
        // given
        let chunk = Doc.chunk(text: "x", scope: "future_scope", status: "future_status", content: Doc.content(state: "future_content", reason: "why", bytes: 1))
        // when
        let decoded = try Self.chunk(chunk)
        // then
        #expect(decoded.scope.rawValue == "future_scope" && decoded.status.rawValue == "future_status")
        #expect(decoded.content.state.rawValue == "future_content" && decoded.content.reason == "why")
    }

    @Test func givenSyntheticChunkWithNonUtf8PathBytes_whenDecoded_thenPathBytesAreExact() throws {
        // given
        let bytes: [UInt8] = [0x61, 0xFF, 0x2F, 0x62]
        // when
        let decoded = try Self.chunk(Doc.chunk(path: nil, pathB64: Self.b64(bytes)))
        // then
        #expect(decoded.path.bytes == Data(bytes) && decoded.path.utf8String == nil)
    }

    @Test func givenSyntheticChunkWhoseContentBytesDifferFromTotalBytes_whenDecoded_thenItIsRejected() {
        // given
        let mismatched = Doc.chunk(text: "abcd", content: Doc.content(bytes: 5))
        let matching = Doc.chunk(text: "abcd", content: Doc.content(bytes: 4))
        // when / then
        #expect(Doc.decodeChunk(mismatched) == nil)
        #expect(Doc.decodeChunk(matching) != nil)
    }

    @Test func givenSyntheticFinishedAssembler_whenAnotherChunkIsAppended_thenAlreadyFinishedIsRefused() throws {
        // given
        var assembler = try Self.assembler()
        try assembler.append(Self.chunk(Doc.chunk(text: "", total: 0)))
        let again = try Self.chunk(Doc.chunk(text: "", total: 0))
        // when / then
        #expect(throws: TaskChangesAssemblyError.alreadyFinished) { try assembler.append(again) }
        #expect(throws: Never.self) { try assembler.finish() }
    }

    // MARK: Assembly

    private static func assembler(path: String = "a.txt") throws -> TaskChangesTextAssembler {
        TaskChangesTextAssembler(selector: try Doc.selector(path: path))
    }

    @Test func givenSyntheticThreeUtf8Chunks_whenAssembled_thenThePatchIsTheirConcatenation() throws {
        // given
        var assembler = try Self.assembler()
        let parts = ["diff --git a/a b/a\n", "+one \u{1F642}\n", "+two\n"]
        let sizes = parts.map(\.utf8.count)
        let total = sizes.reduce(0, +)
        // when
        try assembler.append(Self.chunk(Doc.chunk(text: parts[0], total: total, cursor: "c1")))
        let afterFirst = assembler.nextCursor
        try assembler.append(Self.chunk(Doc.chunk(text: parts[1], offset: sizes[0], total: total, cursor: "c2")))
        try assembler.append(Self.chunk(Doc.chunk(text: parts[2], offset: sizes[0] + sizes[1], total: total)))
        let patch = try assembler.finish()
        // then
        #expect(afterFirst == "c1" && assembler.nextCursor == nil)
        #expect(patch.utf8String == parts.joined() && patch.encoding == .utf8 && patch.selector == assembler.selector)
        #expect(patch.bytes.count == parts.joined().utf8.count)
    }

    @Test func givenSyntheticBase64ChunkSplitInsideACharacter_whenAssembled_thenBytesAreExactAndOnlyTheWholeIsText() throws {
        // given
        var assembler = try Self.assembler()
        let first: [UInt8] = [0x2B, 0x63, 0xC3]
        let second: [UInt8] = [0xA9, 0x0A]
        // when
        let one = try Self.chunk(Doc.chunk(text: nil, textB64: Self.b64(first), total: 5, cursor: "c1"))
        let two = try Self.chunk(Doc.chunk(text: nil, textB64: Self.b64(second), offset: 3, total: 5))
        try assembler.append(one)
        try assembler.append(two)
        let patch = try assembler.finish()
        // then
        #expect(String(data: one.bytes, encoding: .utf8) == nil)
        #expect(patch.bytes == Data(first + second) && patch.encoding == .base64 && patch.utf8String == "+c\u{E9}\n")
    }

    @Test func givenSyntheticNonUtf8Patch_whenAssembled_thenBytesAreExactAndUtf8StringIsNil() throws {
        // given
        var assembler = try Self.assembler()
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0xC0, 0x80, 0x41]
        // when
        try assembler.append(Self.chunk(Doc.chunk(text: nil, textB64: Self.b64(bytes))))
        let patch = try assembler.finish()
        // then
        #expect(patch.bytes == Data(bytes) && patch.utf8String == nil)
        #expect(patch.displayString.contains("\u{FFFD}") && patch.displayString.hasSuffix("A"))
    }

    @Test func givenSyntheticBinaryRowWithEmptyText_whenAssembled_thenPatchIsEmptyAndKeepsItsContentState() throws {
        // given
        var assembler = try Self.assembler(path: "i.bin")
        let chunk = Doc.chunk(text: "", total: 0, path: "i.bin", status: "added", content: Doc.content(state: "binary", bytes: 0))
            .setting(["binary"], to: .bool(true))
.setting(["additions"], to: .null)
.setting(["deletions"], to: .null)
        // when
        try assembler.append(Self.chunk(chunk))
        let patch = try assembler.finish()
        // then
        #expect(patch.bytes.isEmpty && patch.binary && patch.content.state == .binary && patch.additions == nil)
    }

    @Test func givenSyntheticEncodingSwitchBetweenChunks_whenAppended_thenItIsRefused() throws {
        // given
        var assembler = try Self.assembler()
        try assembler.append(Self.chunk(Doc.chunk(text: "ab", total: 4, cursor: "c1")))
        let switched = try Self.chunk(Doc.chunk(text: nil, textB64: Self.b64([0x63, 0x64]), offset: 2, total: 4))
        // when / then
        #expect(throws: TaskChangesAssemblyError.encodingChanged) { try assembler.append(switched) }
    }

    @Test(arguments: [1, 3, 0])
    func givenSyntheticSecondChunkNotStartingWhereTheFirstEnded_whenAppended_thenOffsetMismatchIsRefused(offset: Int) throws {
        // given
        var assembler = try Self.assembler()
        try assembler.append(Self.chunk(Doc.chunk(text: "ab", total: 6, cursor: "c1")))
        let next = try Self.chunk(Doc.chunk(text: "cd", offset: offset, total: 6, cursor: "c2"))
        // when / then
        #expect(throws: TaskChangesAssemblyError.offsetMismatch) { try assembler.append(next) }
    }

    @Test func givenSyntheticFirstChunkAtANonZeroOffset_whenAppended_thenOffsetMismatchIsRefused() throws {
        // given
        var assembler = try Self.assembler()
        let late = try Self.chunk(Doc.chunk(text: "cd", offset: 2, total: 4))
        // when / then
        #expect(throws: TaskChangesAssemblyError.offsetMismatch) { try assembler.append(late) }
    }

    @Test(arguments: ["root", "scope", "path", "path-truncated"])
    func givenSyntheticChunkForAnotherRow_whenAppended_thenSelectorMismatchIsRefused(mode: String) throws {
        // given
        var assembler = try Self.assembler()
        let chunk: JSONValue = switch mode {
        case "root": Doc.chunk(root: "/other")
        case "scope": Doc.chunk(scope: "committed_range")
        case "path": Doc.chunk(path: "b.txt")
        default: Doc.chunk(pathTruncated: true)
        }
        // when / then
        #expect(throws: TaskChangesAssemblyError.selectorMismatch) { try assembler.append(Self.chunk(chunk)) }
    }

    @Test(arguments: ["total", "status", "content", "binary", "capture", "additions"])
    func givenSyntheticSecondChunkWithChangedDocumentFacts_whenAppended_thenDocumentChangedIsRefused(change: String) throws {
        // given
        var assembler = try Self.assembler()
        try assembler.append(Self.chunk(Doc.chunk(text: "ab", total: 6, cursor: "c1")))
        var second = Doc.chunk(text: "cd", offset: 2, total: 6, cursor: "c2")
        switch change {
        case "total": second = Doc.chunk(text: "cd", offset: 2, total: 7, cursor: "c2")
        case "status": second = second.setting(["status"], to: .string("added"))
        case "content": second = second.setting(["content", "reason"], to: .string("task_limit"))
        case "binary": second = second.setting(["binary"], to: .bool(true))
        case "additions": second = second.setting(["additions"], to: .number(9))
        default: second = second.setting(["capture", "reason"], to: .string("no_repository"))
        }
        let chunk = try Self.chunk(second)
        // when / then
        #expect(throws: TaskChangesAssemblyError.documentChanged) { try assembler.append(chunk) }
    }

    @Test func givenSyntheticSecondChunkOfAnotherTask_whenAppended_thenTaskChangedIsRefused() throws {
        // given
        var assembler = try Self.assembler()
        try assembler.append(Self.chunk(Doc.chunk(text: "ab", total: 4, cursor: "c1")))
        let other = try Self.chunk(Doc.chunk(task: "other", text: "cd", offset: 2, total: 4))
        // when / then
        #expect(throws: TaskChangesAssemblyError.taskChanged) { try assembler.append(other) }
    }

    @Test func givenSyntheticRepeatedTextCursor_whenAppended_thenItIsRefused() throws {
        // given
        var assembler = try Self.assembler()
        try assembler.append(Self.chunk(Doc.chunk(text: "ab", total: 6, cursor: "same")))
        let again = try Self.chunk(Doc.chunk(text: "cd", offset: 2, total: 6, cursor: "same"))
        // when / then
        #expect(throws: TaskChangesAssemblyError.repeatedCursor) { try assembler.append(again) }
    }

    @Test func givenSyntheticAssemblerBeforeTheLastChunk_whenFinished_thenItIsUnfinished() throws {
        // given
        var assembler = try Self.assembler()
        // when / then
        #expect(throws: TaskChangesAssemblyError.unfinished) { try assembler.finish() }
        try assembler.append(Self.chunk(Doc.chunk(text: "ab", total: 4, cursor: "c1")))
        #expect(throws: TaskChangesAssemblyError.unfinished) { try assembler.finish() }
    }

    @Test func givenSyntheticOneByteChunks_whenMoreThanTheChunkCeilingArrive_thenTooManyChunksIsRefused() throws {
        // given
        var assembler = try Self.assembler()
        let total = TaskChangesLimits.maxTextChunks + 1
        // when
        for index in 0 ..< TaskChangesLimits.maxTextChunks {
            try assembler.append(Self.chunk(Doc.chunk(text: "x", offset: index, total: total, cursor: "c\(index)")))
        }
        let beyond = try Self.chunk(Doc.chunk(text: "x", offset: TaskChangesLimits.maxTextChunks, total: total))
        // then
        #expect(throws: TaskChangesAssemblyError.tooManyChunks) { try assembler.append(beyond) }
    }

    @Test func givenSyntheticSingleChunkOfExactly64KiB_whenAssembled_thenItIsAccepted() throws {
        // given
        var assembler = try Self.assembler()
        let text = String(repeating: "a", count: TaskChangesLimits.maxTextBytes)
        // when
        try assembler.append(Self.chunk(Doc.chunk(text: text)))
        let patch = try assembler.finish()
        // then
        #expect(patch.bytes.count == 65_536)
    }

    // MARK: Privacy

    @Test func givenSyntheticChunkAndPatchWithDiffText_whenDescribed_thenNoDiffTextAppears() throws {
        // given
        var assembler = try Self.assembler()
        let chunk = try Self.chunk(Doc.chunk(text: "+\(Self.secret)\n"))
        try assembler.append(chunk)
        let patch = try assembler.finish()
        // when
        let renderings = [String(describing: chunk), String(reflecting: chunk), "\(chunk)", chunk.description, chunk.debugDescription,
                          String(describing: patch), String(reflecting: patch), "\(patch)", patch.description, patch.debugDescription]
        // then
        for rendering in renderings { #expect(!rendering.contains(Self.secret), "\(rendering)") }
        #expect(patch.description == "TaskChangesPatch(\(patch.bytes.count) bytes)")
    }

    @Test func givenSyntheticAssemblerHoldingDiffText_whenDescribed_thenNoDiffTextAppears() throws {
        // given
        var assembler = try Self.assembler()
        try assembler.append(Self.chunk(Doc.chunk(text: "+\(Self.secret)\n")))
        // when
        var dumped = ""
        dump(assembler, to: &dumped)
        let renderings = [String(describing: assembler), String(reflecting: assembler), dumped]
        // then
        for rendering in renderings { #expect(!rendering.contains(Self.secret)) }
    }

    @Test func givenSyntheticBase64ChunkWithDiffText_whenDescribed_thenNeitherTextNorBase64Appears() throws {
        // given
        let encoded = Data(Self.secret.utf8).base64EncodedString()
        let chunk = try Self.chunk(Doc.chunk(text: nil, textB64: encoded))
        // when
        let rendering = String(describing: chunk) + String(reflecting: chunk)
        // then
        #expect(!rendering.contains(Self.secret) && !rendering.contains(encoded))
    }

    @Test(arguments: [
        TaskChangesAssemblyError.taskChanged, .documentChanged, .alreadyFinished, .duplicateRow, .rowLimitExceeded, .noProgress, .repeatedCursor, .unfinished,
        .rowCountMismatch, .selectorMismatch, .offsetMismatch, .encodingChanged, .sizeExceeded, .tooManyChunks
    ])
    func givenAssemblyError_whenMessaged_thenItIsAFixedNonEmptyDescriptionWithoutDiffText(error: TaskChangesAssemblyError) {
        // given / when
        let message = error.message
        // then
        #expect(!message.isEmpty && !message.contains(Self.secret))
        #expect(message.hasPrefix("task-changes"))
    }
}
