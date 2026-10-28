import Foundation
import HfRepository
import HfUI
import MonitorCore

struct QualificationCard: Equatable, Identifiable, Sendable {
    let id: String
    let model: HarnessQualificationModel
    let owner: String?
    init(id: String, model: HarnessQualificationModel, owner: String? = nil) {
        self.id = id; self.model = model; self.owner = owner
    }
}

/// One mounted consumer; all adoption and provider-check ordering belongs to the shared actor.
@Observable
@MainActor
final class QualificationPresentation {
    private(set) var cards: [QualificationCard] = []
    private(set) var isReady = false
    private(set) var runtime: QualificationRuntimeToken?
    private(set) var isChecking = false
    @ObservationIgnored private let session: QualificationSession
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var identityContext = "Harness"
    @ObservationIgnored private var boundary: Task<Void, Never>?

    init(session: QualificationSession) { self.session = session }

    func prepare(request: QualificationRequest? = nil) {
        if let request { identityContext = Self.identityContext(request) }
        cards = []
        generation = UUID()
        isReady = false
        runtime = nil
        operation?.cancel()
        operation = nil
        let previous = boundary
        boundary = Task { [session] in await previous?.value; await session.invalidate() }
    }

    func discover(_ request: QualificationRequest) async -> Bool {
        identityContext = Self.identityContext(request)
        observe()
        let current = UUID()
        generation = current
        isReady = false
        runtime = nil
        await boundary?.value
        guard generation == current, !Task.isCancelled else { return false }
        let snapshot = await session.discover(request)
        guard generation == current, !Task.isCancelled else { return false }
        await apply(snapshot)
        guard generation == current, !Task.isCancelled else { return false }
        isReady = snapshot.isReady
        runtime = snapshot.isReady ? snapshot.runtime : nil
        return generation == current && isReady
    }

    @discardableResult
    func check(completion: @escaping @MainActor () -> Void = {}) -> Task<Void, Never>? {
        operation?.cancel()
        let current = UUID()
        generation = current
        isReady = false
        runtime = nil
        isChecking = true
        operation = Task { [weak self, session] in
            await self?.boundary?.value
            guard let self, generation == current, !Task.isCancelled else { return }
            let snapshot = await session.check()
            guard generation == current, !Task.isCancelled else { return }
            await apply(snapshot)
            guard generation == current, !Task.isCancelled else { return }
            isReady = snapshot.isReady
            runtime = snapshot.isReady ? snapshot.runtime : nil
            if isReady { completion() }
        }
        return operation
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        generation = UUID()
        isReady = false
        runtime = nil
        let previous = boundary
        boundary = Task { [weak self, session] in
            await previous?.value
            await session.cancel()
            let snapshot = await session.snapshot
            await self?.apply(snapshot)
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        operation?.cancel()
        operation = nil
        generation = UUID()
        isReady = false
        runtime = nil
        let previous = boundary
        boundary = Task { [session] in await previous?.value; await session.invalidate() }
    }

    private func observe() {
        guard observation == nil else { return }
        observation = Task { [weak self, session] in
            for await snapshot in await session.snapshots() {
                guard !Task.isCancelled else { return }
                await self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: QualificationSession.Snapshot) async {
        let current = generation
        guard snapshot == (await session.snapshot) else { return }
        let context = identityContext
        let cards = await Task.detached { Self.cards(snapshot, context: context) }.value
        guard current == generation, !Task.isCancelled else { return }
        guard snapshot == (await session.snapshot), current == generation else { return }
        if self.cards != cards { self.cards = cards }
        let checking = snapshot.phase == .checking
        if isChecking != checking { isChecking = checking }
    }

    private nonisolated static func cards(_ snapshot: QualificationSession.Snapshot, context: String) -> [QualificationCard] {
        let rows = snapshot.plan?.requirements ?? []
        if rows.isEmpty {
            let (state, message) = status(snapshot, ready: snapshot.isReady)
            return [.init(id: "qualification", model: .init(identity: context, state: state,
                                                           message: message, features: [], canCheck: canCheck(snapshot)))]
        }
        return rows.map { row in
            var (state, message) = status(snapshot, ready: row.isReady)
            if case .settled = snapshot.phase, !row.isReady {
                if row.features.values.contains(where: { $0.source == .failedAtRuntime }) {
                    state = .failedAtRuntime
                } else if row.features.values.contains(where: { $0.source == .failed }) {
                    state = .failed
                } else if row.identity == nil, row.unavailableReason != nil {
                    state = .unavailable
                }
            }
            if snapshot.phase == .checking {
                message = snapshot.checkingIdentity?.backend == row.backend ? "Checking required features…" :
                    snapshot.completedBackends.contains(row.backend) ? "Check finished. Reconciling evidence…" : "Waiting for this harness check…"
            }
            let name = BackendStyle.displayName(row.backend)
            let identity = row.identity.map { name + " · " + $0.version } ?? name
            if row.requiredFeatures.isEmpty, snapshot.phase == .settled {
                message = row.id.hasPrefix("settings/") ? "This harness declares no qualification features." : "No qualification required for this request."
            }
            let features = row.requiredFeatures.map { name in
                let feature = row.features[name]
                let progress = snapshot.checkingIdentity?.backend == row.backend ? "Checking" :
                    snapshot.completedBackends.contains(row.backend) ? "Checked" : "Queued"
                let result = state == .checking ? progress : feature.map { feature in
                    let failed = feature.source == .failed || feature.source == .failedAtRuntime
                    let label = feature.isReady ? "Ready" : failed ? "Failed" : "Unavailable"
                    return label + " · " + feature.source.rawValue
                } ?? "Unavailable"
                return HarnessQualificationModel.Feature(id: name, result: result, reason: feature?.reason ?? "")
            }
            return .init(id: row.id, model: .init(identity: identity, state: state,
                                                 message: message, features: features, reason: row.unavailableReason ?? "", canCheck: canCheck(snapshot),
                                                 actionTitleOverride: rows.count > 1 ? multiHarnessAction(state) : nil))
        }
    }

    private nonisolated static func multiHarnessAction(_ state: HarnessQualificationModel.State) -> String? {
        switch state {
        case .checking: "Cancel check"
        case .ready: "Check required harnesses again"
        case .failed, .failedAtRuntime, .cancelled: "Retry required harnesses"
        case .notChecked, .binaryChanged: "Check required harnesses"
        case .unavailable, .unsupported: nil
        }
    }

    private nonisolated static func identityContext(_ request: QualificationRequest) -> String {
        switch request {
        case .harness(let backend): BackendStyle.displayName(backend)
        case .workflow: "Workflow harnesses"
        case .task(let options): options.first(where: { $0.hasPrefix("--backend=") })
            .map { BackendStyle.displayName(String($0.dropFirst("--backend=".count))) } ?? "Harness"
        }
    }

    private nonisolated static func canCheck(_ snapshot: QualificationSession.Snapshot) -> Bool {
        switch snapshot.phase {
        case .idle, .discovering, .invalidated: false
        default: true
        }
    }

    private nonisolated static func status(_ snapshot: QualificationSession.Snapshot, ready: Bool) -> (HarnessQualificationModel.State, String) {
        switch snapshot.phase {
        case .idle: (.notChecked, "Check the required harness features before running.")
        case .discovering: (.notChecked, "Reading cached harness qualification…")
        case .checking: (.checking, "Checking required features…")
        case .settled: ready ? (.ready, "Required features are ready.") :
            (.notChecked, "Required feature evidence is unavailable. Check this harness explicitly.")
        case .cancelled: (.cancelled, "Check cancelled. Late results will not enable launch.")
        case .invalidated: (.binaryChanged, "The request changed. Fresh qualification evidence is required.")
        case .failed(let failure):
            switch failure {
            case .tool(.unsupportedCommand):
                (.unsupported, "Harness qualification is unavailable in the selected engine. A supporting managed runtime is required.")
            case .runtimeChanged, .evidenceChanged: (.binaryChanged, failure.displayMessage)
            case .missingIdentity: (.unavailable, failure.displayMessage)
            default: (.failed, failure.displayMessage)
            }
        }
    }
}
