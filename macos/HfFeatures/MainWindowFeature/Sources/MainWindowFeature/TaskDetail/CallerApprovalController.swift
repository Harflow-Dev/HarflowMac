import Foundation
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
    private(set) var supportsCallerResponses = false
    private(set) var awaitingDecisionCount: Int?
    private(set) var reveal: CallerApprovalReveal?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var targetTask: String?
    @ObservationIgnored private var targetRun: String?
    @ObservationIgnored private var details: [String: CallerApprovalRequest] = [:]
    @ObservationIgnored private var expanded: Set<String> = []
    private struct BlockedResult {
        let request: CallerApprovalRequest
        let message: String
        var capabilityLoss = false
    }

    @ObservationIgnored private var blocked: [String: BlockedResult] = [:]
    @ObservationIgnored private var pollingEnabled = true
    @ObservationIgnored private var pendingFocus: CallerApprovalReveal?
    @ObservationIgnored private var listCurrent = false
    @ObservationIgnored private var responseWork: Task<Void, Never>?
    @ObservationIgnored private var refreshWork: Task<Void, Never>?
    @ObservationIgnored private var pendingReveal = false
    @ObservationIgnored private var poll: Task<Void, Never>?

    init(useCase: any CallerApprovalUseCase) { self.useCase = useCase }

    var hasMorePending: Bool {
        guard let awaitingDecisionCount else { return nextCursor != nil || acquisitionLimited }
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
    }

    func stop() {
        generation = UUID()
        pendingReveal = false
        listCurrent = false
        responseWork?.cancel(); responseWork = nil
        refreshWork?.cancel(); refreshWork = nil
        poll?.cancel(); poll = nil
        isLoading = false; isSubmitting = false; isCurrentDetail = false
        for index in cards.indices where cards[index].canRespond { cards[index].canRespond = false }
    }

    func selectTarget(taskID: String?, workflowRunID: String?) async {
        stop()
        targetTask = taskID; targetRun = workflowRunID
        clearPresentation()
        await refresh()
    }

    func refresh(loadMore: Bool = false) async {
        guard !isLoading, !isSubmitting, targetTask != nil || targetRun != nil else { return }
        let token = generation
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let capability = (try? await useCase.supportsMonitorResponseForCallerApprovals()) ?? false
            guard generation == token, !Task.isCancelled else { return }
            if supportsCallerResponses != capability { supportsCallerResponses = capability }
            let acquired = try await acquirePage(loadMore: loadMore, token: token)
            guard generation == token, !Task.isCancelled else { return }
            applyPage(acquired.page)
            if acquisitionLimited != acquired.limited { acquisitionLimited = acquired.limited }
            await acquireDetails(acquired.page.requests, token: token)
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

    private func applyPage(_ page: CallerApprovalPage) {
        listCurrent = true
        blocked = blocked.filter { id, result in
            guard let current = page.requests.first(where: { $0.id == id }) else { return false }
            return Self.sameCurrent(result.request, current) && !(result.capabilityLoss && supportsCallerResponses)
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
        let retainedIDs = Set(requests.map(\.id))
        let awaitingCount = awaitingDecisionCount
        var awaitingIDs = Set<String>()
        var acquiredIDs = Set<String>()
        var values = loadMore ? requests : []
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
            values += page.requests
            acquiredIDs.formUnion(page.requests.map(\.id))
            awaitingIDs.formUnion(page.requests.filter(Self.awaiting).map(\.id))
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
        return Acquisition(page: CallerApprovalPage(requests: listed, nextCursor: cursor, total: acquiredTotal), limited: limited)
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
            if let result, Self.sameCurrent(result, request), result.text("disposition") == request.text("disposition"),
               result.text("delivery") == request.text("delivery"), result.raw["decision"] == request.raw["decision"] {
                details[request.id] = result
            }
        }
        details = details.filter { key, _ in listed.contains { $0.id == key } }
    }

    static func awaiting(_ request: CallerApprovalRequest) -> Bool {
        request.text("disposition") == "pending" && request.text("delivery") == "pending"
            && request.text("decision").isEmpty && request.text("effective_decision").isEmpty
            && request.text("system_rejection").isEmpty && request.text("decided_by").isEmpty
    }

    static func visuallyPending(_ request: CallerApprovalRequest) -> Bool {
        !["decided", "expired", "system_rejected", "invalidated", "cancelled", "unsupported"].contains(request.text("disposition"))
            && request.text("decision").isEmpty && request.text("effective_decision").isEmpty
            && request.text("decided_by").isEmpty && request.text("system_rejection").isEmpty
    }

    static func knownState(_ request: CallerApprovalRequest) -> Bool {
        ["pending", "decided", "expired", "system_rejected", "invalidated", "cancelled", "unsupported"].contains(request.text("disposition"))
            && ["pending", "reserved", "sending", "sent", "delivery_unknown", "failed"].contains(request.text("delivery"))
            && ["unknown", "succeeded", "failed", "not_observed"].contains(request.text("execution_outcome"))
            && optionalEnum(request, key: "decided_by", values: ["", "caller", "harflow"])
            && optionalEnum(request, key: "responder", values: ["", "caller", "monitor"])
            && ["decision", "effective_decision", "delivered_decision"].allSatisfy {
                optionalEnum(request, key: $0, values: ["", "approve", "reject"])
            }
            && (request.raw["system_rejection"] == nil || request.raw["system_rejection"] == .null
                || request.raw["system_rejection"]?.stringValue != nil)
    }

    private static func optionalEnum(_ request: CallerApprovalRequest, key: String, values: Set<String>) -> Bool {
        guard let value = request.raw[key], value != .null else { return true }
        guard let text = value.stringValue else { return false }
        return values.contains(text)
    }

    static func validIdentity(_ request: CallerApprovalRequest) -> Bool {
        !request.id.isEmpty && !request.taskID.isEmpty && !request.digest.isEmpty
            && (request.raw["owner_revision"]?.intValue ?? 0) > 0 && !request.text("generation").isEmpty
    }

    static func sameCurrent(_ first: CallerApprovalRequest, _ second: CallerApprovalRequest) -> Bool {
        first.id == second.id && first.taskID == second.taskID && first.digest == second.digest
            && first.revision == second.revision && first.raw["generation"] == second.raw["generation"]
            && first.raw["interaction_owner"] == second.raw["interaction_owner"]
    }

    func inspect(_ request: CallerApprovalRequest) async {
        selectedID = request.id
        await refresh()
        detail = details[request.id]
        isCurrentDetail = cards.first { $0.id == request.id }?.canRespond == true
    }

    func toggle(_ requestID: String) {
        guard let index = cards.firstIndex(where: { $0.id == requestID }), !cards[index].pending else { return }
        if !expanded.insert(requestID).inserted { expanded.remove(requestID) }
        let card = cards[index]
        if expanded.contains(requestID), details[requestID] == nil {
            requestRefresh()
        }
        cards[index] = CallerApprovalCardModel(request: card.request, action: card.action, pending: false,
            expanded: expanded.contains(requestID), canRespond: false, showsDecisionControls: card.showsDecisionControls, notice: card.notice,
            submitting: false, focusToken: nil)
    }

    func revealPending() {
        pendingReveal = true
        guard let card = cards.first(where: \.pending) else { return }
        pendingReveal = false
        let value = CallerApprovalReveal(requestID: card.id, token: UUID())
        reveal = value
        pendingFocus = value
        if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index].focusToken = value.token }
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
        refreshWork = Task { [weak self] in await self?.refresh(loadMore: loadMore) }
    }

    func submit(_ decision: String, requestID: String) {
        guard listCurrent, !isLoading, !isSubmitting else { return }
        responseWork = Task { [weak self] in await self?.respond(decision, requestID: requestID) }
    }

    func respond(_ decision: String, requestID: String? = nil) async {
        guard listCurrent, !isLoading, ["approve", "reject"].contains(decision), !isSubmitting,
              let id = requestID ?? selectedID,
              let card = cards.first(where: { $0.id == id }), card.canRespond,
              let request = details[id], Self.awaiting(request), request.complete, Self.validIdentity(request),
              let listed = requests.first(where: { $0.id == id }), Self.sameCurrent(request, listed),
              Self.awaiting(listed), Self.knownState(listed),
              (request.deadline ?? .distantPast) > Date() else { return }
        let token = generation
        isSubmitting = true; error = nil; isCurrentDetail = false
        defer { if generation == token { isSubmitting = false } }
        await publishCards(token: token)
        guard generation == token, !Task.isCancelled, listCurrent else { return }
        do {
            let response = try await useCase.respond(request, decision: decision)
            guard generation == token, !Task.isCancelled else { return }
            guard Self.confirmsResponse(response, for: request, decision: decision) else {
                throw ToolError.unknownOutcome(message: "The approval response did not confirm the submitted decision.")
            }
            detail = response
            details[id] = response
            if let index = requests.firstIndex(where: { $0.id == id }) { requests[index] = response }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            recordResponseFailure(error, request: request)
        }
        guard generation == token else { return }
        isSubmitting = false
        await refresh()
    }

    static func confirmsResponse(_ response: CallerApprovalRequest, for request: CallerApprovalRequest, decision: String) -> Bool {
        let responder = response.raw["responder"]
        let responderOmitted = responder == nil || responder == .null
        return response.id == request.id && response.taskID == request.taskID && response.digest == request.digest
            && response.raw["generation"] == request.raw["generation"]
            && response.raw["interaction_owner"] == request.raw["interaction_owner"]
            && (response.revision ?? 0) > (request.revision ?? 0) && validIdentity(response)
            && response.complete && knownState(response) && response.raw["action"] == request.raw["action"]
            && response.text("decision") == decision && response.text("decided_by") == "caller"
            && response.text("delivery") != "pending" && (responder?.stringValue == "monitor" || responderOmitted)
    }

    private func recordResponseFailure(_ error: Error, request: CallerApprovalRequest) {
        let toolError = error as? ToolError
        let reason = toolError?.callerApprovalResponseReason
        if let toolError, case .unsupportedCommand = toolError {
            supportsCallerResponses = false
            blocked[request.id] = BlockedResult(request: request,
                message: "Harflow responses are unavailable with this engine. Respond through the owning caller's MCP or CLI.", capabilityLoss: true)
        } else if let reason {
            let message = CallerApprovalPresentation.refusalMessage(reason)
            blocked[request.id] = BlockedResult(request: request, message: message, capabilityLoss: reason == .unsupported)
        } else {
            blocked[request.id] = BlockedResult(request: request,
                message: "The result could not be confirmed. This request is read-only here and your answer will not be retried.")
        }
        self.error = blocked[request.id]?.message
    }

    private func notice(for request: CallerApprovalRequest, ownerSupported: Bool, full: Bool, now: Date, knownEnums: Bool) -> String? {
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

    private func publishCards(token: UUID, finishingRefresh: Bool = false) async {
        let values = requests.map { details[$0.id] ?? $0 }
        let actions = await Task.detached(priority: .userInitiated) {
            values.map { CallerApprovalAction.build($0) }
        }.value
        guard generation == token, !Task.isCancelled else { return }
        if finishingRefresh { isLoading = false }
        let now = Date()
        let next = zip(values, actions).map { request, action in
            let pending = Self.visuallyPending(request)
            let ownerSupported = request.isMonitorOwned || (request.interactionOwner == .caller && supportsCallerResponses)
            let known = Self.knownState(request) && action.knownEnums
            let full = details[request.id] != nil && request.complete && action.covered && action.knownEnums && Self.validIdentity(request)
            let canRespond = pending && Self.awaiting(request) && known && ownerSupported && full && listCurrent
                && blocked[request.id] == nil && !isSubmitting && (request.deadline ?? .distantPast) > now
            let notice = notice(for: request, ownerSupported: ownerSupported, full: full, now: now, knownEnums: action.knownEnums)
            return CallerApprovalCardModel(request: request, action: action, pending: pending, expanded: pending || expanded.contains(request.id),
                canRespond: canRespond, showsDecisionControls: pending && Self.knownState(request) && ownerSupported,
                notice: notice, submitting: isSubmitting,
                focusToken: pendingFocus?.requestID == request.id ? pendingFocus?.token : nil)
        }
        if cards != next { cards = next }
        if pendingReveal { revealPending() }
        if let selectedID { detail = details[selectedID]; isCurrentDetail = next.first { $0.id == selectedID }?.canRespond == true }
    }
}

struct CallerApprovalReveal: Equatable, Sendable {
    let requestID: String
    let token: UUID
}
