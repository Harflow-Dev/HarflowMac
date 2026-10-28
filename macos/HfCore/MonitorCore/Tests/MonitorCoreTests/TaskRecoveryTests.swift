import Foundation
@testable import MonitorCore
import Testing

@Suite
struct TaskRecoveryTests {
    private func value(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test
    func givenValidRecoveryPage_whenDecoded_thenTextToolEventsAndCursorArePreserved() throws {
        let page = try #require(RecoveryActivityPage(try value("""
        {"source":"backend_transcript","display_only":true,"events":[
          {"source_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "kind":"assistant_text","source_ts":"2026-10-23T00:00:00Z","text":"hello"},
          {"source_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","kind":"tool_call","call_id":"x","tool":"Read","input_preview":"{}"},
          {"source_id":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "kind":"tool_result","call_id":"x","ok":true,"output_tail":"done"}],
          "next_cursor":"next","reset":false,"has_more":false,"notices":[]}
        """)))
        #expect(page.events.count == 3)
        #expect(page.nextCursor == "next")
        #expect(page.events[0].sourceID.count == 64)
        if case .assistantText(let text, _, _) = page.events[0].kind { #expect(text == "hello") } else { Issue.record("expected text") }
        if case .toolCall(let call) = page.events[1].kind { #expect(call.callID == "recovery:x") } else { Issue.record("expected call") }
        if case .toolResult(let result) = page.events[2].kind { #expect(result.callID == "recovery:x") } else { Issue.record("expected result") }
    }

    @Test
    func givenMalformedRecoveryPage_whenDecoded_thenItIsRejected() throws {
        let malformed = try value("""
        {"source":"backend_transcript","display_only":true,"events":[],
          "reset":false,"has_more":true,"notices":[]}
        """)
        #expect(RecoveryActivityPage(malformed) == nil)
    }

    @Test
    func givenSupervisionCaptureCutoff_whenDecoded_thenNoticeExplainsDisplayOnlyRecovery() throws {
        let supervision = try #require(TaskSupervision(try value("""
        {"owner_state":"dead","process_state":"alive","capture_state":"lost_with_owner",
          "live_input_state":"closed_with_owner","last_captured_output_at":"2026-10-23T00:00:00Z",
          "last_captured_output_source":"raw_stream_log_mtime"}
        """)))
        #expect(supervision.notices.contains { $0.contains("lost with its owner") })
        #expect(!supervision.notices.contains { $0.contains("Last raw-log write") })
        #expect(supervision.lastCapturedOutputAt == "2026-10-23T00:00:00Z")
    }

    @Test
    func givenQualifiedParentObservation_whenDecoded_thenIdentityAndNullableTimeArePreserved() throws {
        // given
        let source = try value("""
        {"owner_state":"alive","process_state":"alive","capture_state":"live","live_input_state":"open",
         "adopted_after_restart":{"at":null,"observer_kind":"parent_process",
         "previous_server":{"pid":21,"start_time":"old"},"observing_process":{"pid":21,"start_time":"new"}}}
        """)
        // when
        let supervision = try #require(TaskSupervision(source))
        // then
        #expect(supervision.hasHealthyContinuity)
        #expect(supervision.restartObservation?.observedProcessStartedAt == nil)
        #expect(supervision.restartObservation?.observerKind == "parent_process")
        #expect(supervision.notices.isEmpty)
    }

    @Test(arguments: ["null", "{}", "{\"previous_server\":{\"pid\":true,\"start_time\":\"x\"}}",
                      "{\"previous_server\":{\"pid\":2.5,\"start_time\":\"x\"}}"])
    func givenMalformedOptionalRestart_whenDecoded_thenSupervisionSurvivesWithoutRestart(restart: String) throws {
        // given
        let source = try value("{\"owner_state\":\"alive\",\"adopted_after_restart\":\(restart)}")
        // when
        let supervision = try #require(TaskSupervision(source))
        // then
        #expect(supervision.ownerState == "alive")
        #expect(supervision.restartObservation == nil)
    }

    @Test
    func givenLiveOwnerDrainingDeadProcess_whenDecoded_thenNoDispatcherLossWarning() throws {
        // given
        let source = try value("{\"owner_state\":\"alive\",\"process_state\":\"dead\",\"capture_state\":\"live\",\"live_input_state\":\"closed\"}")
        // when
        let supervision = try #require(TaskSupervision(source))
        // then
        #expect(supervision.notices.isEmpty)
        #expect(!supervision.hasHealthyContinuity)
    }

    @Test(arguments: ["undecidable", "unknown", "dead"])
    func givenUncertainOwner_whenDecoded_thenWarningRemains(owner: String) throws {
        // given
        let source = try value("{\"owner_state\":\"\(owner)\",\"capture_state\":\"live\",\"live_input_state\":\"open\"}")
        // when
        let supervision = try #require(TaskSupervision(source))
        // then
        #expect(supervision.notices.contains("Task connection is uncertain."))
        #expect(!supervision.hasHealthyContinuity)
    }

    @Test
    func givenNormallyObservedCompletedTask_whenReadingNotices_thenAbsentOwnerIsNotAWarning() throws {
        // given
        let source = try value("""
        {"task_id":"completed","backend":"claude","status":"completed",
         "supervision":{"owner_state":"undecidable","process_state":"undecidable",
         "capture_state":"observed_terminal","live_input_state":"closed"}}
        """)
        // when
        let task = try #require(TaskInfo(source))
        // then
        #expect(task.notices.isEmpty)
    }

}
