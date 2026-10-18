import Foundation
@testable import MonitorCore
import Testing

@Suite struct EventSummaryTests {
    @Test func givenManyUniqueEdits_whenPublished_thenTotalsStayCompleteAndFilePagesAreBounded() throws {
        var builder = EventSummaryBuilder()
        for index in 1 ... 250 {
            let line = #"{"v":1,"seq":\#(index),"kind":"tool_call","call_id":"\#(index)","tool":"Edit","category":"edit", "#
                + #""path":"\#(index).swift","input_preview":""}"#
            builder.append([try #require(TaskEvent(line: line))])
        }
        #expect(builder.summary.activity.edits == 250)
        #expect(builder.summary.totalFiles == 250)
        #expect(builder.summary.files.count == 100)
        #expect(builder.snapshot(fileLimit: 200).files.count == 200)
        #expect(builder.snapshot(fileLimit: 300).files.count == 250)
    }

    @Test func givenAbsoluteAndRelativeAliases_whenLaterEditUnconfirmed_thenEarlierResultCannotOverrideIt() throws {
        let lines = [
            #"{"v":1,"seq":1,"kind":"task_started","repo_path":"/repo","prompt":"edit"}"#,
            #"{"v":1,"seq":2,"kind":"tool_call","call_id":"old","tool":"Edit","category":"edit","path":"/repo/a.swift","input_preview":""}"#,
            #"{"v":1,"seq":3,"kind":"tool_call","call_id":"new","tool":"Edit","category":"edit","path":"a.swift","input_preview":""}"#,
            #"{"v":1,"seq":4,"kind":"tool_result","call_id":"old","ok":true,"output_tail":""}"#
        ]
        var builder = EventSummaryBuilder()
        builder.append(lines.compactMap(TaskEvent.init(line:)))
        #expect(builder.summary.totalFiles == 1)
        #expect(builder.summary.files == [EditedFile(path: "a.swift", status: .unconfirmed)])
    }
}
