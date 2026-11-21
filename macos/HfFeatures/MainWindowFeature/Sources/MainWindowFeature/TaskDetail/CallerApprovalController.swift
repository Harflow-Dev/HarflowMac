import Foundation
import HfRepository
import MonitorCore
import Observation

// MARK: - CallerApprovalController

@Observable
@MainActor
final class CallerApprovalController {
    @ObservationIgnored private let useCase: any CallerApprovalUseCase
    private(set) var requests: [CallerApprovalRequest] = []
    private(set) var cards: [CallerApprovalCardModel] = []
    private(set) var total = 0
    private(set) var nextCursor: String?
    private(set) var acquisitionLimited = false
    private(set) var detail: CallerApprovalRequest?
    private(set) var isCurrentDetail = false
    private(set) var selectedID: String?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var isSubmitting = false
    private(set) var isResponseQueued = false
    private(set) var supportsCallerResponses = false
    private(set) var awaitingDecisionCount: Int?
    private(set) var reveal: CallerApprovalReveal?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var responseGeneration = UUID()
    @ObservationIgnored private var activeResponse: CallerApprovalRequest?
    @ObservationIgnored private var scopeRefreshPending = false
    @ObservationIgnored private var targetTask: String?
    @ObservationIgnored private var targetRun: String?
    @ObservationIgnored private var details: [String: CallerApprovalRequest] = [:]
    @ObservationIgnored private var expanded: Set<String> = []
    @ObservationIgnored private var manuallyCollapsed: Set<String> = []
    @ObservationIgnored private var seededPending = false
    @ObservationIgnored private var disclosureIdentities: [String: String] = [:]
    @ObservationIgnored private var rootScope: WorkflowRootApprovalScope?
    @ObservationIgnored private let pendingDisclosures: Bool
    @ObservationIgnored private let retainsOutcomeFocus: Bool
    private struct BlockedResult {
        let request: CallerApprovalRequest
        let message: String
        var capabilityLoss = false
        var winner: CallerApprovalWinner?
        var current: CallerApprovalRequest?
        var temporaryBusy = false
        var refreshable = false
    }

    @ObservationIgnored private var blocked: [String: BlockedResult] = [:]
    @ObservationIgnored private var pollingEnabled = true
    @ObservationIgnored private var pendingFocus: CallerApprovalReveal?
    @ObservationIgnored private var listCurrent = false
    @ObservationIgnored private var responseContext: ApprovalResponseContext?
    @ObservationIgnored private var responseWork: Task<Void, Never>?
    @ObservationIgnored private var refreshWork: Task<Void, Never>?
    @ObservationIgnored private var pendingReveal = false
    @ObservationIgnored private var poll: Task<Void, Never>?

    init(useCase: any CallerApprovalUseCase, pendingDisclosures: Bool = false, retainsOutcomeFocus: Bool = false) {
        self.useCase = useCase
        self.pendingDisclosures = pendingDisclosures
        self.retainsOutcomeFocus = retainsOutcomeFocus
    }

    var hasMorePending: Bool {
        guard rootScope == nil, let awaitingDecisionCount else { return nextCursor != nil || acquisitionLimited }
        return awaitingDecisionCount > requests.filter(Self.awaiting).count
    }

    func setAwaitingDecisionCount(_ value: Int?) {
        if awaitingDecisionCount != value { awaitingDecisionCount = value }
    }

    func hasRetainedRequests(for taskID: String) -> Bool {
        targetTask == taskID && (!requests.isEmpty || total > 0)
    }

    func start(taskID: String, polls: Bool = true) {
        guard targetTask != taskID || poll == nil || pollingEnabled != polls else { return }
        let targetChanged = targetTask != taskID
        stop()
        pollingEnabled = polls
        targetTask = taskID; targetRun = nil
        if targetChanged { clearPresentation() }
        let token = generation
        poll = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while polls, !Task.isCancelled, generation == token {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, generation == token else { return }
                await refresh()
            }
        }
    }

    private func clearPresentation() {
        requests = []; cards = []; details = [:]; blocked = [:]; expanded = []
        detail = nil; selectedID = nil; isCurrentDetail = false; total = 0; nextCursor = nil
        acquisitionLimited = false; error = nil; reveal = nil; pendingFocus = nil
        manuallyCollapsed = []; seededPending = false; disclosureIdentities = [:]
    }

    func stop() {
        generation = UUID()
        responseGeneration = UUID()
        activeResponse = nil; scopeRefreshPending = false; isResponseQueued = false
        pendingReveal = false
        listCurrent = false
        responseWork?.cancel(); responseWork = nil
        refreshWork?.cancel(); refreshWork = nil
        poll?.cancel(); poll = nil
        isLoading = false; isSubmitting = false; isCurrentDetail = false
        for index in cards.indices where cards[index].canRespond { cards[index].canRespond = false }
    }

    func selectTarget(taskID: String?, workflowRunID: String?, rootScope: WorkflowRootApprovalScope? = nil) async {
        if targetTask == taskID, targetRun == workflowRunID,
           let rootScope, self.rootScope?.rootID == rootScope.rootID {
            updateRootScope(rootScope)
            restartRootRead()
            await refresh()
            return
        }
        let changed = targetTask != taskID || targetRun != workflowRunID || self.rootScope != rootScope
        stop()
        targetTask = taskID; targetRun = workflowRunID
        self.rootScope = rootScope
        if changed { clearPresentation() }
        await refresh()
    }

    /// A changed poll policy must replace a cancelled read while retaining exact response settlement.
    private func restartRootRead() {
        generation = UUID()
        refreshWork?.cancel(); refreshWork = nil
        isLoading = false; listCurrent = false; isCurrentDetail = false
        for index in cards.indices where cards[index].canRespond { cards[index].canRespond = false }
        if isSubmitting || isResponseQueued { scopeRefreshPending = true }
    }

    /// Reconciles direct membership without replacing the run's retained disclosure or pagination state.
    func updateRootScope(_ scope: WorkflowRootApprovalScope) {
        guard targetRun == scope.rootID, rootScope?.rootID == scope.rootID, rootScope != scope else { return }
        rootScope = scope
        generation = UUID()
        refreshWork?.cancel(); refreshWork = nil
        isLoading = false; listCurrent = false; isCurrentDetail = false
        requests = requests.filter(scope.contains)
        cards = cards.filter { scope.contains($0.request) }.map { card in
            var card = card; card.canRespond = false; return card
        }
        total = requests.count
        details = details.filter { scope.contains($0.value) }
        blocked = blocked.filter { scope.contains($0.value.request) }
        if let detail, !scope.contains(detail) { self.detail = nil; selectedID = nil }
        let retained = Set(requests.map(\.id))
        expanded.formIntersection(retained); manuallyCollapsed.formIntersection(retained)
        disclosureIdentities = disclosureIdentities.filter { retained.contains($0.key) }
        if let activeResponse, !scope.contains(activeResponse) {
            responseGeneration = UUID()
            responseWork?.cancel(); responseWork = nil
            self.activeResponse = nil; isSubmitting = false; isResponseQueued = false
        }
        scopeRefreshPending = isSubmitting || isResponseQueued
    }

    func refresh(loadMore: Bool = false, recoverPreflight: Bool = false) async {
        guard !isLoading, !isSubmitting, !isResponseQueued, targetTask != nil || targetRun != nil else { return }
        let token = generation
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let context = try useCase.responseContext()
            resetPresentationIfContextChanged(context)
            let capability = (try? await useCase.supportsMonitorResponseForCallerApprovals()) ?? false
            guard generation == token, !Task.isCancelled else { return }
            if supportsCallerResponses != capability { supportsCallerResponses = capability }
            let acquired = try await acquirePage(loadMore: loadMore, token: token)
            guard generation == token, !Task.isCancelled else { return }
            try validateResponseContext(context)
            responseContext = context
            applyPage(acquired.page)
            if acquisitionLimited != acquired.limited { acquisitionLimited = acquired.limited }
            await acquireDetails(acquired.page.requests, token: token)
            if recoverPreflight, let context {
                await recoverRefusals(context: context, token: token)
            }
            try validateResponseContext(context)
            await publishCards(token: token, finishingRefresh: true)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            let message = String(describing: error)
            if self.error != message { self.error = message }
            isCurrentDetail = false
            listCurrent = false
            await publishCards(token: token, finishingRefresh: true)
        }
    }

    private func resetPresentationIfContextChanged(_ context: ApprovalResponseContext?) {
        if let previous = responseContext, previous != context { clearPresentation() }
    }

    private func validateResponseContext(_ context: ApprovalResponseContext?) throws {
        if let context, !useCase.isResponseContextCurrent(context) {
            throw ToolError.unknownOutcome(message: "Refresh to review the current action.")
        }
    }

    private func recoverRefusals(context: ApprovalResponseContext, token: UUID) async {
        for (id, value) in blocked where value.refreshable {
            guard await useCase.canReviewAgain(value.request, context: context) else { continue }
            guard generation == token, useCase.isResponseContextCurrent(context), responseContext == context else { return }
            blocked[id] = nil
            if error == value.message { error = nil }
        }
    }

    private func applyPage(_ page: CallerApprovalPage) {
        listCurrent = true
        blocked = blocked.filter { id, result in
            guard let current = page.requests.first(where: { $0.id == id }) else { return false }
            return Self.sameCurrent(result.request, current)
        }
        let retainedError = blocked.values
.filter { result in
            page.requests.contains { $0.id == result.request.id && Self.visuallyPending($0) }
        }
.map(\.message)
.sorted()
.first
        if error != retainedError { error = retainedError }
        if requests != page.requests { requests = page.requests }
        if total != page.total { total = page.total }
        if nextCursor != page.nextCursor { nextCursor = page.nextCursor }
    }

    private struct Acquisition {
        let page: CallerApprovalPage
        let limited: Bool
    }

    private static let acquisitionByteLimit = 8 * 1024 * 1024

    private nonisolated static func metadataBytes(_ requests: [CallerApprovalRequest]) async -> Int {
        await Task.detached {
            requests.reduce(0) { $0 + JSONValue.object($1.raw).rendered().utf8.count }
        }
.value
    }

    private func acquirePage(loadMore: Bool, token: UUID) async throws -> Acquisition {
        let retainedIDs = Set(requests.filter { rootScope?.contains($0) ?? true }.map(\.id))
        let awaitingCount = rootScope == nil ? awaitingDecisionCount : nil
        var awaitingIDs = Set<String>()
        var acquiredIDs = Set<String>()
        var values = loadMore ? requests.filter { rootScope?.contains($0) ?? true } : []
        var cursor = loadMore ? nextCursor : nil
        var seenCursors = Set<String>()
        var pageCount = 0
        var sourceBytes = await Self.metadataBytes(values)
        var acquiredTotal = total
        var limited = false
        repeat {
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            guard sourceBytes < Self.acquisitionByteLimit else { limited = true; break }
            let page = try await useCase.page(taskID: targetTask, workflowRunID: targetRun, cursor: cursor)
            let pageBytes = await Self.metadataBytes(page.requests)
            guard generation == token, !Task.isCancelled else { throw CancellationError() }
            acquiredTotal = page.total
            // Do not consume a cursor whose whole page cannot fit. Ordinary refresh retains only
            // freshly acquired rows, so budget exhaustion never promotes stale retained actions.
            guard pageBytes <= Self.acquisitionByteLimit - sourceBytes else { limited = true; break }
            sourceBytes += pageBytes
            let qualified = page.requests.filter { rootScope?.contains($0) ?? true }
            values += qualified
            acquiredIDs.formUnion(qualified.map(\.id))
            awaitingIDs.formUnion(qualified.filter(Self.awaiting).map(\.id))
            cursor = page.nextCursor
            pageCount += 1
            if let next = cursor, !seenCursors.insert(next).inserted { limited = true; break }
            if page.requests.isEmpty, cursor != nil { limited = true; break }
            if !loadMore, let awaitingCount, awaitingIDs.count >= awaitingCount, retainedIDs.isSubset(of: acquiredIDs) { break }
            // Reordering cannot evict a previously retained request: normal polls continue until
            // its identity and known pending discovery are revalidated, or the source/budget ends.
            // Explicit Load more adds at most one 32-page chunk, including retained metadata bytes.
        } while cursor != nil && (pageCount < 32 || (!loadMore && !retainedIDs.isSubset(of: acquiredIDs)))
        let acquired = values
        let listed = await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            return acquired.filter { seen.insert($0.id).inserted }.sorted(by: CallerApprovalPresentation.orderedBefore)
        }.value
        let page = CallerApprovalPage(requests: listed, nextCursor: cursor, total: rootScope == nil ? acquiredTotal : listed.count)
        return Acquisition(page: page, limited: limited)
    }

    private func acquireDetails(_ listed: [CallerApprovalRequest], token: UUID) async {
        for request in listed {
            if let retained = details[request.id], Self.sameCurrent(retained, request) {
                // Status can settle without changing the action's digest/revision/generation.
                var raw = request.raw
                raw["action"] = retained.raw["action"]
                raw["complete"] = retained.raw["complete"]
                details[request.id] = CallerApprovalRequest(raw: raw)
            } else {
                details[request.id] = nil
            }
            guard details[request.id] == nil, Self.visuallyPending(request) || expanded.contains(request.id) else { continue }
            let result = try? await useCase.detail(request)
            guard generation == token, !Task.isCancelled else { return }
            if let result, rootScope?.contains(result) ?? true, Self.sameCurrent(result, request), result.text("disposition") == request.text("disposition"),
               result.text("delivery") == request.text("delivery"), result.raw["decision"] == request.raw["decision"] {
                details[request.id] = result
            }
        }
        details = details.filter { key, _ in listed.contains { $0.id == key } }
    }

    static func awaiting(_ request: CallerApprovalRequest) -> Bool { request.isAwaitingDecision }

    static func visuallyPending(_ request: CallerApprovalRequest) -> Bool { request.isVisuallyPending }

    static func knownState(_ request: CallerApprovalRequest) -> Bool { request.hasKnownState }

    static func validIdentity(_ request: CallerApprovalRequest) -> Bool { request.hasValidIdentity }

    static func sameCurrent(_ first: CallerApprovalRequest, _ second: CallerApprovalRequest) -> Bool { first.isSameCurrent(as: second) }

    func inspect(_ request: CallerApprovalRequest) async {
        selectedID = request.id
        await refresh()
        detail = details[request.id]
        isCurrentDetail = cards.first { $0.id == request.id }?.canRespond == true
    }

    func toggle(_ requestID: String) {
        guard let index = cards.firstIndex(where: { $0.id == requestID }), pendingDisclosures || !cards[index].pending else { return }
        let card = cards[index]
        guard pendingDisclosures else {
            if !expanded.insert(requestID).inserted { expanded.remove(requestID) }
            if expanded.contains(requestID), details[requestID] == nil { requestRefresh() }
            cards[index] = CallerApprovalCardModel(request: card.request, action: card.action, pending: false,
                expanded: expanded.contains(requestID), canRespond: false, showsDecisionControls: card.showsDecisionControls,
                awaitingDecision: card.awaitingDecision, notice: card.notice,
                submitting: false, focusToken: nil)
            return
        }
        let opens = !card.expanded
        if opens {
            expanded.insert(requestID); manuallyCollapsed.remove(requestID)
        } else {
            expanded.remove(requestID); manuallyCollapsed.insert(requestID); seededPending = true
        }
        if opens, details[requestID] == nil { requestRefresh() }
        cards[index] = CallerApprovalCardModel(request: card.request, action: card.action, pending: card.pending,
            expanded: opens, canRespond: card.canRespond, showsDecisionControls: card.showsDecisionControls,
            awaitingDecision: card.awaitingDecision, showsRefresh: card.showsRefresh, notice: card.notice,
            submitting: card.submitting, focusToken: card.focusToken)
    }

    func revealPending() {
        pendingReveal = true
        guard let card = cards.first(where: \.pending) else { return }
        pendingReveal = false
        if pendingDisclosures, let index = cards.firstIndex(where: { $0.id == card.id }), !card.expanded {
            toggle(cards[index].id)
        }
        focusRequest(card.id)
    }

    private func focusRequest(_ requestID: String) {
        guard let index = cards.firstIndex(where: { $0.id == requestID }) else { return }
        let value = CallerApprovalReveal(requestID: requestID, token: UUID())
        reveal = value; pendingFocus = value
        cards[index].focusToken = value.token
    }

    private func focusOutcome(_ requestID: String, generation: UUID) {
        guard retainsOutcomeFocus, responseGeneration == generation else { return }
        focusRequest(requestID)
    }

    func acknowledgeFocus(requestID: String, token: UUID) {
        guard pendingFocus?.requestID == requestID, pendingFocus?.token == token else { return }
        pendingFocus = nil
        if let index = cards.firstIndex(where: { $0.id == requestID }), cards[index].focusToken == token {
            cards[index].focusToken = nil
        }
    }

    func acknowledgeScroll(requestID: String, token: UUID) {
        guard reveal?.requestID == requestID, reveal?.token == token else { return }
        reveal = nil
    }

    func requestRefresh(loadMore: Bool = false) {
        refreshWork?.cancel()
        refreshWork = Task { [weak self] in await self?.refresh(loadMore: loadMore, recoverPreflight: !loadMore) }
    }

}

// MARK: - Caller approval responses

extension CallerApprovalController {
    func submit(_ decision: String, requestID: String) {
        guard listCurrent, !isLoading, !isSubmitting, !isResponseQueued else { return }
        guard pendingDisclosures else {
            responseWork = Task { [weak self] in await self?.respond(decision, requestID: requestID) }
            return
        }
        // Reserve the accepted UI intent before yielding, so a poll cannot overtake its fresh admission.
        isResponseQueued = true
        let token = responseGeneration
        responseWork = Task { [weak self] in
            guard let self, responseGeneration == token, !Task.isCancelled else { return }
            defer {
                if responseGeneration == token {
                    isResponseQueued = false
                    if scopeRefreshPending { scopeRefreshPending = false; requestRefresh() }
                }
            }
            await respond(decision, requestID: requestID)
        }
    }

    func respond(_ decision: String, requestID: String? = nil) async {
        guard responseContext.map({ useCase.isResponseContextCurrent($0) }) != false,
              listCurrent, !isLoading, ["approve", "reject"].contains(decision), !isSubmitting,
              let id = requestID ?? selectedID,
              let card = cards.first(where: { $0.id == id }), card.canRespond,
              let request = details[id], rootScope?.contains(request) ?? true, Self.awaiting(request), request.complete, Self.validIdentity(request),
              let listed = requests.first(where: { $0.id == id }), Self.sameCurrent(request, listed),
              Self.awaiting(listed), Self.knownState(listed),
              (request.deadline ?? .distantPast) > Date() else { return }
        let token = responseGeneration
        isSubmitting = true; error = nil; isCurrentDetail = false
        activeResponse = request
        defer {
            if responseGeneration == token {
                isSubmitting = false; activeResponse = nil
                if scopeRefreshPending { scopeRefreshPending = false; requestRefresh() }
            }
        }
        await publishCards(token: generation)
        guard responseGeneration == token, !Task.isCancelled, listCurrent, rootScope?.contains(request) ?? true else { return }
        do {
            let response = try await useCase.respond(request, decision: decision, context: responseContext)
            guard responseGeneration == token, !Task.isCancelled, rootScope?.contains(request) ?? true else { return }
            guard Self.confirmsResponse(response, for: request, decision: decision) else {
                throw ToolError.unknownOutcome(message: "The approval response did not confirm the submitted decision.")
            }
            detail = response
            details[id] = response
            if let index = requests.firstIndex(where: { $0.id == id }) { requests[index] = response }
        } catch {
            guard responseGeneration == token, !Task.isCancelled, rootScope?.contains(request) ?? true else { return }
            recordResponseFailure(error, request: request)
        }
        guard responseGeneration == token else { return }
        isSubmitting = false
        isResponseQueued = false
        scopeRefreshPending = false
        await refresh()
        focusOutcome(id, generation: token)
    }

    private func recordResponseFailure(_ error: Error, request: CallerApprovalRequest) {
        if error is ApprovalResponseBusy {
            blocked[request.id] = BlockedResult(request: request, message: "An approval response is already in progress.", temporaryBusy: true)
            return
        }
        let refusal = error as? ApprovalResponseRefusal
        let toolError = refusal?.error ?? (error as? ToolError)
        let reason = toolError?.callerApprovalResponseReason
        if let winner = toolError?.callerApprovalWinner, winner.requestID == request.id, winner.taskID == request.taskID {
            let label = winner.answeredBy == .caller ? "Already answered by the caller" : "Answered in Harflow"
            blocked[request.id] = BlockedResult(request: request, message: label + " · " + winner.decision, winner: winner)
        } else if let toolError, case .unsupportedCommand = toolError {
            supportsCallerResponses = false
            blocked[request.id] = BlockedResult(request: request,
                message: "Harflow responses are unavailable with this engine. Respond through the owning caller's MCP or CLI.", capabilityLoss: true)
        } else if let reason {
            let message = CallerApprovalPresentation.refusalMessage(reason)
            blocked[request.id] = BlockedResult(request: request, message: message, capabilityLoss: reason == .unsupported)
        } else {
            blocked[request.id] = BlockedResult(request: request,
                message: refusal != nil ? (toolError?.message ?? ApprovalResponseOutcome.uncertainMessage) : ApprovalResponseOutcome.uncertainMessage)
        }
        blocked[request.id]?.current = refusal?.current
        blocked[request.id]?.refreshable = refusal != nil && toolError?.callerApprovalWinner == nil
            && reason != .expired && reason != .settled
        self.error = blocked[request.id]?.message
    }

    private func notice(for request: CallerApprovalRequest, ownerSupported: Bool, full: Bool, now: Date, knownEnums: Bool) -> String? {
        if let refusal = blocked[request.id], refusal.winner != nil, Self.sameCurrent(refusal.request, request) { return refusal.message }
        let pending = Self.visuallyPending(request)
        let known = Self.knownState(request) && knownEnums
        if !pending {
            return request.text("delivery") == "delivery_unknown" ? "Delivery is unknown. The decision will not be retried." : nil
        }
        if let refusal = blocked[request.id], Self.sameCurrent(refusal.request, request) { return refusal.message }
        if !listCurrent { return "The current action could not be refreshed. Responses are unavailable." }
        if !known || request.interactionOwner == nil { return "This engine reported an unrecognized approval state. Responses are unavailable." }
        if !ownerSupported { return "Caller-owned request. This engine cannot accept a Harflow response. Respond through the owning caller's MCP or CLI." }
        if !full { return "The complete current action is unavailable. Approval remains disabled." }
        if (request.deadline ?? .distantPast) <= now { return "The deadline has passed. Waiting for the engine to settle this request." }
        return nil
    }

    private func reconcileBlockedResponses(context responseContext: ApprovalResponseContext) {
            for (id, value) in blocked where value.temporaryBusy {
                if useCase.retainedResponse(value.request, context: responseContext) != .busy {
                    blocked[id] = nil
                    if error == value.message { error = nil }
                }
            }
            for request in details.values {
                guard let held = useCase.retainedResponse(request, context: responseContext) else { continue }
                switch held {
                case .refused(let error, _): recordResponseFailure(error, request: request)
                case .uncertain: recordResponseFailure(ToolError.unknownOutcome(message: ApprovalResponseOutcome.uncertainMessage), request: request)
                case .busy:
                    blocked[request.id] = BlockedResult(request: request, message: "An approval response is already in progress.", temporaryBusy: true)
                case .recorded: break
                }
            }
    }

    private func presentedRequest(_ listed: CallerApprovalRequest) -> CallerApprovalRequest {
            var request = details[listed.id] ?? listed
            if let responseContext, let held = useCase.retainedResponse(request, context: responseContext) {
                switch held {
                case .recorded(let response): request = response
                case .refused(_, let current): if let current, !current.isVisuallyPending { request = current }
                default: break
                }
            }
            if let current = blocked[request.id]?.current, !current.isVisuallyPending { request = current }
            guard let winner = blocked[request.id]?.winner else { return request }
            var raw = request.raw
            raw["decision"] = .string(winner.decision)
            raw["responder"] = .string(winner.answeredBy.rawValue)
            raw["decided_at"] = .number(winner.answeredAt)
            return CallerApprovalRequest(raw: raw)
    }

    private func publishCards(token: UUID, finishingRefresh: Bool = false) async {
        if let responseContext { reconcileBlockedResponses(context: responseContext) }
        let values = requests.map(presentedRequest)
        let actions = await Task.detached(priority: .userInitiated) {
            values.map { CallerApprovalAction.build($0) }
        }.value
        guard generation == token, !Task.isCancelled else { return }
        if finishingRefresh { isLoading = false }
        let now = Date()
        if pendingDisclosures {
            let identities = Dictionary(values.map { request in
                let fields = [request.taskID, request.id, request.text("generation"), request.text("root_workflow_run_id"),
                              request.text("workflow_run_id"), request.text("workflow_execution_id"), request.text("workflow_node_id")]
                return (request.id, fields.joined(separator: ":"))
            }, uniquingKeysWith: { first, _ in first })
            expanded = expanded.filter { identities[$0] == disclosureIdentities[$0] }
            manuallyCollapsed = manuallyCollapsed.filter { identities[$0] == disclosureIdentities[$0] }
            disclosureIdentities = identities
            if !seededPending, let first = values.first(where: Self.visuallyPending) {
                expanded.insert(first.id); seededPending = true
            }
        }
        let next = zip(values, actions).map { request, action in
            let pending = Self.visuallyPending(request)
            let ownerSupported = request.isMonitorOwned || (request.interactionOwner == .caller && supportsCallerResponses)
            let full = details[request.id] != nil && request.complete && action.covered && action.knownEnums && Self.validIdentity(request)
            let canRespond = details[request.id] != nil && listCurrent && blocked[request.id] == nil && !isSubmitting
                && request.isEligibleForMonitorResponse(supportsCallerResponses: supportsCallerResponses, now: now)
            let notice = notice(for: request, ownerSupported: ownerSupported, full: full, now: now, knownEnums: action.knownEnums)
            let needsReview = blocked[request.id] != nil || request.text("disposition") == "expired" || request.text("delivery") == "delivery_unknown"
            let isExpanded = pendingDisclosures
                ? (expanded.contains(request.id) || (needsReview && !manuallyCollapsed.contains(request.id)))
                : (pending || needsReview || expanded.contains(request.id))
            return CallerApprovalCardModel(request: request, action: action,
                pending: pending && blocked[request.id] == nil, expanded: isExpanded,
                canRespond: canRespond, showsDecisionControls: pending && Self.knownState(request) && ownerSupported && blocked[request.id] == nil,
                awaitingDecision: pending,
                showsRefresh: blocked[request.id]?.refreshable == true,
                notice: notice, submitting: isSubmitting,
                focusToken: pendingFocus?.requestID == request.id ? pendingFocus?.token : nil)
        }
        if cards != next { cards = next }
        if pendingReveal { revealPending() }
        if let selectedID { detail = details[selectedID]; isCurrentDetail = next.first { $0.id == selectedID }?.canRespond == true }
    }
}
