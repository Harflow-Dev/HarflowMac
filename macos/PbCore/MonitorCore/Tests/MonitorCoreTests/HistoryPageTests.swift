import Foundation
@testable import MonitorCore
import Testing

struct HistoryPageTests {
    private func raw(_ count: Int) -> [String: JSONValue] {
        ["items": .array((0 ..< count).map { .object(["task_id": .string("task-\($0)")]) }),
         "next_cursor": .null, "has_more": .bool(false), "bootstrap_pending": .bool(false)]
    }

    @Test func givenOverPageLimit_whenDecoded_thenEntirePageIsRefused() {
        // given / when / then
        #expect(TaskHistoryPage(raw: raw(100))?.items.count == 100)
        #expect(TaskHistoryPage(raw: raw(101)) == nil)
    }

    @Test func givenMalformedMemberOrCursor_whenDecoded_thenItCannotSilentlyHideHistory() {
        // given
        var page = raw(1)
        page["items"] = .array([.object(["wrong_id": .string("missing")])])
        // when / then
        #expect(TaskHistoryPage(raw: page) == nil)
        page = raw(1)
        page["has_more"] = .bool(true)
        #expect(HistoryPage(raw: page) == nil)
    }

    @Test func givenBootstrapReceipt_whenDecoded_thenEmptyHistoryIsExplicitlyPending() throws {
        // given
        var page = raw(0)
        page["bootstrap_pending"] = .bool(true)
        page["total_active_count"] = .number(250)
        // when
        let decoded = try #require(HistoryPage(raw: page))
        // then
        #expect(decoded.bootstrapPending)
        #expect(decoded.items.isEmpty)
        #expect(decoded.totalActiveCount == 250)
    }

    @Test func givenOversizedLegacyFallback_whenDecoded_thenKnownPageRemainsAvailableAndIncomplete() throws {
        var page = raw(100)
        page["history_incomplete"] = .bool(true)
        page["counts_complete"] = .bool(false)
        page["next_cursor"] = .string("next-page")
        page["has_more"] = .bool(true)
        let decoded = try #require(TaskHistoryPage(raw: page))
        #expect(decoded.items.count == 100)
        #expect(decoded.page.historyIncomplete)
        #expect(!decoded.page.bootstrapPending)
        #expect(!decoded.page.countsComplete)
        #expect(decoded.page.nextCursor == "next-page")
    }

    @Test func givenAuthorityBlockedReceipt_whenDecoded_thenItDoesNotPretendToBeTransientBootstrap() throws {
        var page = raw(0)
        page["authority_incomplete"] = .bool(true)
        page["history_incomplete"] = .bool(true)
        let decoded = try #require(HistoryPage(raw: page))
        #expect(decoded.authorityIncomplete)
        #expect(decoded.historyIncomplete)
        #expect(!decoded.bootstrapPending)
    }
}
