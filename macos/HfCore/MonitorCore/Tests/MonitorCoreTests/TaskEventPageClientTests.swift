import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskEventPageClientTests

struct TaskEventPageClientTests {
    @Test func givenRepeatedReads_whenCapabilityDisappears_thenEveryReadProbesOnce() async throws {
        // given
        let probes = EventReadCounter()
        let runner = RecordingRunner { call in
            call.arguments.first == "version-info"
                ? eventProbe(call.environment, capability: probes.next() == 1) : eventOutput(eventPageRaw())
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let first = await client.taskEvents(taskID: "task")
        let second = await client.taskEvents(taskID: "task")
        // then
        #expect(try first.get().taskID == "task")
        guard case .failure(.unsupportedCommand) = second else { Issue.record("Missing capability accepted"); return }
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info", "task-events", "version-info"])
    }

    @Test(arguments: ["foreign-root", "ctl", "events"])
    func givenIncompatibleProbe_whenRead_thenNoCommandLaunches(mode: String) async {
        // given
        let runner = RecordingRunner { eventProbe($0.environment, mode: mode) }
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner).taskEvents(taskID: "task")
        // then
        guard case .failure = result else { Issue.record("Incompatible probe accepted"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: ["newest", "oldest", "cursor", "default", "kinds"])
    func givenOptions_whenRead_thenArgumentsAreProtectedAndKindsNormalized(mode: String) async throws {
        // given
        var raw = eventPageRaw()
        raw["task_id"] = .string("--help")
        let selection: TaskEventKindSelection = mode == "default" ? .default : mode == "kinds" ? .kinds(["usage", "assistant_text", "usage"]) : .all
        if mode == "default" { raw["kinds"] = .string("default") }
        if mode == "kinds" { raw["kinds"] = .array([.string("assistant_text"), .string("usage")]) }
        let output = eventOutput(raw)
        let runner = RecordingRunner { $0.arguments.first == "version-info" ? eventProbe($0.environment) : output }
        let position: TaskEventPagePosition = mode == "cursor" ? .cursor("--opaque🙂") : mode == "oldest" ? .oldest : .newest
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
            .taskEvents(taskID: "--help", position: position, limit: 200, selection: selection)
        // then
        #expect(try result.get().taskID == "--help")
        let arguments = try #require(runner.calls.first?.arguments)
        #expect(Array(arguments.suffix(3)) == ["--json", "--", "--help"])
        #expect(arguments.contains("--limit=200"))
        #expect(arguments.contains(mode == "cursor" ? "--cursor=--opaque🙂" : "--from=\(mode == "oldest" ? "oldest" : "newest")"))
        if mode == "kinds" {
            #expect(arguments.contains("--kinds=assistant_text,usage"))
        } else if mode == "default" {
            #expect(!arguments.contains("--all-kinds"))
        } else {
            #expect(arguments.contains("--all-kinds"))
        }
    }

    @Test(arguments: ["zero", "large", "empty-cursor", "long-cursor", "nul-cursor", "empty-kinds", "empty-kind", "comma", "nul-kind"])
    func givenInvalidRequest_whenRead_thenNoProcessLaunches(mode: String) async {
        // given
        let runner = RecordingRunner { _ in Issue.record("Invalid request launched"); return eventOutput(eventPageRaw()) }
        let position: TaskEventPagePosition = mode == "empty-cursor" ? .cursor("") : mode == "long-cursor"
            ? .cursor(String(repeating: "🙂", count: 2049)) : mode == "nul-cursor" ? .cursor("a\0b") : .newest
        let selections: [String: TaskEventKindSelection] = ["empty-kinds": .kinds([]), "empty-kind": .kinds([""]),
                                                          "comma": .kinds(["a,b"]), "nul-kind": .kinds(["a\0b"])]
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
            .taskEvents(taskID: "task", position: position, limit: mode == "zero" ? 0 : mode == "large" ? 201 : 100,
                        selection: selections[mode] ?? .all)
        // then
        guard case .failure = result else { Issue.record("Invalid request accepted"); return }
        #expect(runner.allCalls.isEmpty)
    }

    @Test(arguments: ["cursor-expired", "cursor-invalid", "direct-caller-refused", "pending-launch", "unknown-task"])
    func givenCanonicalRefusal_whenRead_thenStructuredDataSurvives(name: String) async throws {
        // given
        let document = try taskEventPageFixture(name)
        let error = try #require(document["error"]?.objectValue)
        let response = ProcessOutput(exitCode: 1, stdout: ctlJSON(JSONValue.object(document).rendered()), stderr: "")
        let runner = RecordingRunner { $0.arguments.first == "version-info" ? eventProbe($0.environment) : response }
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner).taskEvents(taskID: "task")
        // then
        guard case .failure(let refusal) = result else { Issue.record("Refusal accepted"); return }
        #expect(refusal.refusalCode == error["code"]?.stringValue)
        #expect(refusal.refusalData == error["data"]?.objectValue)
    }

    @Test(arguments: ["exact", "prefix", "wrong-input", "wrong-resolution", "missing", "short"])
    func givenTaskIdentity_whenRead_thenOnlyExactOrProvenPrefixSucceeds(mode: String) async {
        // given
        let requested = mode == "exact" ? "task" : mode == "short" ? "abc" : "abcdefgh"
        var raw = eventPageRaw()
        if mode != "exact" {
            raw["task_id"] = .string("abcdefgh-full")
            if mode != "missing" {
                raw["resolved_from"] = .object(["input": .string(mode == "wrong-input" ? "other" : requested),
                                                "task_id": .string(mode == "wrong-resolution" ? "other" : "abcdefgh-full")])
            }
        }
        let output = eventOutput(raw)
        let runner = RecordingRunner { $0.arguments.first == "version-info" ? eventProbe($0.environment) : output }
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner).taskEvents(taskID: requested)
        // then
        #expect(((try? result.get()) != nil) == (mode == "exact" || mode == "prefix"))
    }

    @Test(arguments: ["document", "nested-product", "nested-format", "nested-version", "outer-version"])
    func givenInvalidResponse_whenRead_thenItIsRefused(mode: String) async {
        // given
        var raw = eventPageRaw()
        var record = eventRecordRaw()
        if mode == "nested-product" { record["product"] = .string("foreign") }
        if mode == "nested-format" { record["format"] = .string("foreign.event") }
        if mode == "nested-version" { record["v"] = .number(99) }
        raw["events"] = .array([.object(record)])
        let normal = eventOutput(raw)
        let output: ProcessOutput = if mode == "document" {
            ProcessOutput(exitCode: 0, stdout: Data(repeating: 32, count: 262145) + normal.stdout, stderr: "")
        } else if mode == "outer-version" {
            ProcessOutput(exitCode: 0,
                          stdout: currentEnvelope(JSONValue.object(["v": .number(99), "result": .object(raw)]).rendered(), format: "harflow.ctl"),
                          stderr: "")
        } else { normal }
        let runner = RecordingRunner { $0.arguments.first == "version-info" ? eventProbe($0.environment) : output }
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner).taskEvents(taskID: "task")
        // then
        guard case .failure = result else { Issue.record("Invalid response accepted"); return }
    }

    @Test(arguments: ["probe", "success", "error"])
    func givenGenerationChanges_whenReadReturns_thenLateSuccessAndErrorAreRejected(stage: String) async {
        // given
        let current = EventReadCounter()
        let runner = RecordingRunner { call in
            let probe = call.arguments.first == "version-info"
            if (stage == "probe" && probe) || (stage != "probe" && !probe) { current.next() }
            if probe { return eventProbe(call.environment) }
            if stage == "error" {
                return ProcessOutput(exitCode: 1,
                                     stdout: ctlJSON("{\"error\":{\"code\":\"event_cursor_expired\",\"message\":\"late\",\"data\":{\"reload\":\"newest\"}}}"),
                                     stderr: "")
            }
            return eventOutput(eventPageRaw())
        }
        var client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        client.operationIsCurrent = { current.value == 0 }
        // when
        let result = await client.taskEvents(taskID: "task")
        // then
        guard case .failure(let error) = result else { Issue.record("Stale response escaped"); return }
        #expect(error.refusalCode != "event_cursor_expired")
        #expect(runner.calls.count == (stage == "probe" ? 0 : 1))
    }

    @Test(arguments: ["before", "probe", "success", "error"])
    func givenCancellation_whenReadReturns_thenNoCancelledResponseEscapes(stage: String) async {
        // given
        let runner = RecordingRunner { call in
            let probe = call.arguments.first == "version-info"
            if (stage == "probe" && probe) || ((stage == "success" || stage == "error") && !probe) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            if probe { return eventProbe(call.environment) }
            if stage == "error" {
                return ProcessOutput(exitCode: 1,
                                     stdout: ctlJSON("{\"error\":{\"code\":\"event_cursor_invalid\",\"message\":\"late\"}}"), stderr: "")
            }
            return eventOutput(eventPageRaw())
        }
        let operation = Task {
            if stage == "before" { withUnsafeCurrentTask { $0?.cancel() } }
            return await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner).taskEvents(taskID: "task")
        }
        // when
        let result = await operation.value
        // then
        guard case .failure(let error) = result else { Issue.record("Cancelled response escaped"); return }
        #expect(error.refusalCode != "event_cursor_invalid")
        #expect(runner.calls.count == (stage == "success" || stage == "error" ? 1 : 0))
        if stage == "before" { #expect(runner.allCalls.isEmpty) }
    }

    @Test func givenEscapedUnicodeRecord_whenRead_thenWireEscapingDoesNotConsumeRecordBudget() async throws {
        // given
        var raw = eventPageRaw()
        var record = eventRecordRaw()
        record["text"] = .string(String(repeating: "🙂", count: 2000))
        raw["events"] = .array([.object(record)])
        let document = try #require(String(data: eventOutput(raw).stdout, encoding: .utf8))
            .replacingOccurrences(of: "🙂", with: "\\ud83d\\ude42")
        #expect(document.utf8.count > 16384)
        let response = ProcessOutput(exitCode: 0, stdout: Data(document.utf8), stderr: "")
        let runner = RecordingRunner { $0.arguments.first == "version-info" ? eventProbe($0.environment) : response }
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
            .taskEvents(taskID: "task", position: .cursor(String(repeating: "🙂", count: 2048)))
        // then
        #expect(try result.get().events.first?.raw == record)
    }

}
