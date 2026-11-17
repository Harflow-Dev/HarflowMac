import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowBuilderBinding

/// Durable provenance deliberately excludes the child environment and credentials.
struct WorkflowBuilderBinding: Equatable {
    let executable: String
    let stateRoot: String
    let productVersion: String

    init(_ runtime: QualificationRuntimeToken) {
        self.executable = runtime.executable
        self.stateRoot = runtime.context.expectedStateRoot
        self.productVersion = runtime.context.productVersion
    }

    init?(raw: [String: JSONValue]?) {
        guard let raw, raw["v"]?.intValue == 1,
              let executable = raw["executable"]?.stringValue, !executable.isEmpty,
              let stateRoot = raw["expected_state_root"]?.stringValue, !stateRoot.isEmpty,
              let productVersion = raw["product_version"]?.stringValue, !productVersion.isEmpty else { return nil }
        self.executable = executable
        self.stateRoot = stateRoot
        self.productVersion = productVersion
    }

    var raw: [String: JSONValue] {
        ["v": .number(1), "executable": .string(executable),
         "expected_state_root": .string(stateRoot), "product_version": .string(productVersion)]
    }
}

// MARK: - WorkflowBuilderAttempt

struct WorkflowBuilderAttempt {
    let id = UUID()
    let draftID: UUID
    let runtime: QualificationRuntimeToken

    @MainActor var raw: [String: JSONValue] {
        ["id": .string(id.uuidString), "owner": .string(WorkflowVM.builderDispatchOwner),
         "draft_id": .string(draftID.uuidString), "binding": .object(WorkflowBuilderBinding(runtime).raw)]
    }
}

// MARK: - WorkflowVM runtime ownership

extension WorkflowVM {
    @discardableResult
    func validateBuilderRuntime() -> Bool {
        guard selectedRun?.isBuilder == true else { return true }
        guard let builderRuntime, (try? useCase.activityRuntime()) == builderRuntime else {
            selectedRun = nil
            refinementContext = nil
            builderDispatchPending = true
            builderRuntime = nil
            nativeActivityRequestID = UUID()
            nativeActivityTask?.cancel()
            nativeActivityTask = nil
            nativeActivity = nil
            clearArtifacts()
            activityMessageSnapshot = nil
            activityMessageSnapshotRunID = nil
            parallel.setWorkflowTaskIDs([])
            errorText = "The workflow agent runtime changed or is unavailable. Reopen the draft with its original runtime."
            return false
        }
        return true
    }

    func builderCommand(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue] {
        guard validateBuilderRuntime(), !builderDispatchPending || selectedRun != nil else { throw CancellationError() }
        guard selectedRun?.isBuilder == true, let runtime = builderRuntime else {
            return try await useCase.command(command, options: options, positionals: positionals)
        }
        let runID = selectedRun?.id
        let loadID = editorLoadID
        let fence = WorkflowBuilderFence()
        builderSubmissionFence?.invalidate()
        builderSubmissionFence = fence
        let result: [String: JSONValue]
        do {
            result = try await useCase.boundBuilderCommand(command, options: options, positionals: positionals,
                                                          runtime: runtime, isCurrent: { fence.isCurrent() })
        } catch {
            guard fence.isCurrent(), selectedRun?.id == runID, editorLoadID == loadID,
                  (try? useCase.activityRuntime()) == runtime, validateBuilderRuntime() else { throw CancellationError() }
            throw error
        }
        guard fence.isCurrent(), selectedRun?.id == runID, editorLoadID == loadID,
              (try? useCase.activityRuntime()) == runtime, validateBuilderRuntime() else { throw CancellationError() }
        return result
    }

    func builderAcknowledgementIsCurrent(key: String?, draftID: UUID, runID: String, runtime: QualificationRuntimeToken) -> Bool {
        guard let key, let draft = try? draftStore.load(key: key) else { return false }
        return draft["draft_id"]?.stringValue == draftID.uuidString
            && draft["builder_dispatch_pending"] == nil && draft["builder_dispatch_attempt"] == nil
            && draft["builder_session"]?["run"]?["workflow_run_id"]?.stringValue == runID
            && WorkflowBuilderBinding(raw: draft["builder_session"]?["runtime_binding"]?.objectValue) == WorkflowBuilderBinding(runtime)
    }

    func builderContextIsCurrent(_ context: WorkflowRefinementContext, attempt: WorkflowBuilderAttempt) -> Bool {
        builderSubmissionFence?.isCurrent() != false
            && builderAttempt?.id == attempt.id && (try? useCase.activityRuntime()) == attempt.runtime
            && draftID == context.draftID && editorLoadID == context.loadID
            && definition == context.definition && name == context.name && loadedName == context.loadedName
            && revision == context.revision && savedDefinition == context.baseline
    }

    func ownsBuilderAttempt(_ draft: [String: JSONValue], attempt: WorkflowBuilderAttempt) -> Bool {
        draft["draft_id"]?.stringValue == attempt.draftID.uuidString
            && draft["builder_dispatch_attempt"]?.objectValue == attempt.raw
            && draft["builder_dispatch_pending"] == .bool(true)
    }

    func hasBuilderMetadata(_ draft: [String: JSONValue]) -> Bool {
        draft["builder_session"] != nil || draft["builder_dispatch_pending"] != nil
            || draft["builder_dispatch_attempt"] != nil || draft["builder_dispatch_owner"] != nil
    }
}

// MARK: - WorkflowBuilderFence

/// Synchronous transport preflight; the main actor revokes it when its captured editor changes.
final class WorkflowBuilderFence: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true

    func invalidate() { lock.withLock { current = false } }
    func isCurrent() -> Bool { lock.withLock { current } }
}
