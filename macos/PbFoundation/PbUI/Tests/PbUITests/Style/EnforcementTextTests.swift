import MonitorCore
@testable import PbUI
import Testing

@Suite struct EnforcementTextTests {
    
    @Test func givenNilEnforcement_whenReadingLines_thenReturnsNoLines() {
        // given / when
        let lines = EnforcementText.lines(nil)
        
        // then
        #expect(lines.isEmpty)
    }
    
    @Test func givenAFalseClaim_whenReadingLines_thenTheLineIsNotShown() {
        // given — every boolean is a strict claim: only an explicit `true` earns a line, never an
        // absent key or an explicit `false`.
        let enforcement: [String: JSONValue] = ["os_enforced": .bool(false)]
        
        // when
        let lines = EnforcementText.lines(enforcement)
        
        // then
        #expect(lines.isEmpty)
    }
    
    @Test func givenOsEnforcedTrue_whenReadingLines_thenIncludesTheSandboxLine() {
        // given
        let enforcement: [String: JSONValue] = ["os_enforced": .bool(true)]
        
        // when
        let lines = EnforcementText.lines(enforcement)
        
        // then
        #expect(lines == ["Restrictions enforced by the OS sandbox"])
    }
    
    @Test func givenCommitPushBlockedTrue_whenReadingLines_thenPrefersTheFullBlockLineOverTheWeakerOne() {
        // given
        let enforcement: [String: JSONValue] = [
            "commit_push_blocked": .bool(true),
            "direct_commit_commands_denied": .bool(true)
        ]
        
        // when
        let lines = EnforcementText.lines(enforcement)
        
        // then
        #expect(lines == ["Git commit and push blocked"])
    }
    
    @Test func givenOnlyDirectCommitCommandsDeniedTrue_whenReadingLines_thenShowsTheWeakerLine() {
        // given
        let enforcement: [String: JSONValue] = ["direct_commit_commands_denied": .bool(true)]
        
        // when
        let lines = EnforcementText.lines(enforcement)
        
        // then
        #expect(lines == ["Direct git commit/push commands denied (not a full block)"])
    }
    
    @Test func givenNetworkAccessString_whenReadingLines_thenReplacesUnderscoresWithSpaces() {
        // given
        let enforcement: [String: JSONValue] = ["network_access": .string("not_controlled")]
        
        // when
        let lines = EnforcementText.lines(enforcement)
        
        // then
        #expect(lines == ["Network: not controlled"])
    }
    
    @Test func givenEveryClaimTrue_whenReadingLines_thenReturnsThemInFixedOrder() {
        // given
        let enforcement: [String: JSONValue] = [
            "os_enforced": .bool(true),
            "writes_confined": .bool(true),
            "commit_push_blocked": .bool(true),
            "publish_attempts_allowed_by_polybridge": .bool(true),
            "network_access": .string("blocked")
        ]
        
        // when
        let lines = EnforcementText.lines(enforcement)
        
        // then
        #expect(lines == [
            "Restrictions enforced by the OS sandbox",
            "File writes confined to the workspace (+ temp dirs)",
            "Git commit and push blocked",
            "Allowed to attempt commit/push/PR",
            "Network: blocked"
        ])
    }
    
    // MARK: - common (Parallel view footer)
    
    @Test func givenNoTasks_whenComputingCommon_thenReturnsNil() {
        // given / when
        let common = EnforcementText.common([])
        
        // then
        #expect(common == nil)
    }
    
    @Test func givenTasksWithNoSharedEnforcement_whenComputingCommon_thenReturnsNil() {
        // given
        let taskA = makeTask(id: "a", enforcement: ["os_enforced": .bool(true)])
        let taskB = makeTask(id: "b", enforcement: ["writes_confined": .bool(true)])
        
        // when
        let common = EnforcementText.common([taskA, taskB])
        
        // then
        #expect(common == nil)
    }
    
    @Test func givenTasksWithAPartiallySharedClaim_whenComputingCommon_thenReturnsOnlyTheIntersection() {
        // given
        let taskA = makeTask(id: "a", enforcement: ["os_enforced": .bool(true), "writes_confined": .bool(true)])
        let taskB = makeTask(id: "b", enforcement: ["os_enforced": .bool(true)])
        
        // when
        let common = EnforcementText.common([taskA, taskB])
        
        // then
        #expect(common == "Enforced for every agent here: Restrictions enforced by the OS sandbox.")
    }
    
    // MARK: - Helpers
    
    private func makeTask(id: String, enforcement: [String: JSONValue]) -> TaskInfo {
        TaskInfo(.object([
            "task_id": .string(id),
            "backend": .string("claude"),
            "status": .string("completed"),
            "enforcement": .object(enforcement)
        ]))!
    }
}
