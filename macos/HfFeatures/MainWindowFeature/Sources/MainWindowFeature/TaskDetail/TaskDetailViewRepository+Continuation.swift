import HfRepository
import MonitorCore

// MARK: - Continue adapter

extension TaskDetailViewRepository {
    func continuationOwner() -> any TaskContinuationRepository { taskContinuationRepository }

    /// Both capabilities come from one handshake on the same captured selected binding.
    func continuationSupport(runtime: QualificationRuntimeToken) async -> Bool {
        guard let client = continuationClient(), QualificationRuntimeToken(client: client) == runtime else { return false }
        let result = await VersionInfoClient(executable: client.executable, environment: client.environment,
                                           context: client.compatibilityContext, runner: client.runner).check()
        guard continuationRuntime() == runtime, client.operationIsCurrent(), !Task.isCancelled,
              case .success(let info) = result else { return false }
        return info.capabilities.contains(CtlCapability.taskContinue) && info.capabilities.contains(CtlCapability.taskSuccessors)
    }
}
