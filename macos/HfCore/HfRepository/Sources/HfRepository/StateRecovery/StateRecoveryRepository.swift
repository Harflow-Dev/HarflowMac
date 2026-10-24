import Combine
import Foundation
import HfUtilities
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - StoreRecoveryState

/// Shared store readiness and explicit recovery lifecycle, separate from managed runtime readiness.
public enum StoreRecoveryState: Equatable, Sendable {
    case idle
    case incompatible(ToolError)
    case inspecting
    case inspected(StateInspection)
    case confirming(StateInspection)
    case recovering(StateInspection)
    case completed(StateRecoveryResult)
    case failed(ToolError, inspection: StateInspection?)
}

// MARK: - StateRecoveryRepository

/// A single shared owner for public engine recovery operations.
@Mockable
public protocol StateRecoveryRepository: Sendable {
    /// Most recent engine completion receipt, retained through subsequent inspections and failures.
    var lastCompletedReceipt: StateRecoveryResult? { get }
    var state: StoreRecoveryState { get }
    func statePublisher() -> AnyPublisher<StoreRecoveryState, Never>
    func report(_ error: ToolError)
    func inspect() async
    func requestConfirmation(inspection: StateInspection)
    func cancelConfirmation()
    func recover(inspection: StateInspection) async
    func invalidate()
}

public extension StateRecoveryRepository {
    var lastCompletedReceipt: StateRecoveryResult? { nil }
}

// MARK: - StateRecoveryRepositoryImpl

/// Serializes recovery without touching private store files or changing executable qualification.
public final class StateRecoveryRepositoryImpl: StateRecoveryRepository, @unchecked Sendable {
    private let toolEnvironment: any ToolEnvironmentRepository
    private let lock = NSRecursiveLock()
    private var generation = 0
    private var busy = false
    private var receipt: StateRecoveryResult?
    @Subjected private var value: StoreRecoveryState = .idle

    public init(toolEnvironment: any ToolEnvironmentRepository) { self.toolEnvironment = toolEnvironment }

    public var lastCompletedReceipt: StateRecoveryResult? { lock.withLock { receipt } }
    public var state: StoreRecoveryState { lock.withLock { value } }
    public func statePublisher() -> AnyPublisher<StoreRecoveryState, Never> { $value.removeDuplicates().eraseToAnyPublisher() }

    public func report(_ error: ToolError) {
        guard error.isStateRecoveryRefusal else { return }
        lock.withLock {
            guard !busy else { return }
            switch value {
            case .idle, .completed: set(.incompatible(error))
            case .incompatible: set(.incompatible(error))
            default: break
            }
        }
    }

    public func inspect() async {
        guard let ticket = beginInspection() else { return }
        let result: Result<StateInspection, ToolError>
        switch toolEnvironment.ctl() {
        case .failure(let error): result = .failure(error)
        case .success(var client):
            client.operationIsCurrent = { [weak self] in self?.isCurrent(ticket) == true }
            result = await client.inspectState()
        }
        lock.withLock {
            busy = false
            guard generation == ticket else { return }
            switch result {
            case .success(let inspection): set(.inspected(inspection))
            case .failure(let error): set(.failed(error, inspection: nil))
            }
        }
    }

    public func requestConfirmation(inspection: StateInspection) {
        lock.withLock {
            guard !busy, inspection.recoverySupported else { return }
            guard case .inspected(let current) = value, current == inspection else { return }
            set(.confirming(inspection))
        }
    }

    public func cancelConfirmation() {
        lock.withLock {
            guard case .confirming(let inspection) = value else { return }
            set(.inspected(inspection))
        }
    }

    public func recover(inspection: StateInspection) async {
        guard let ticket = beginRecovery(inspection) else { return }
        let result: Result<StateRecoveryResult, ToolError>
        switch toolEnvironment.ctl() {
        case .failure(let error): result = .failure(error)
        case .success(var client):
            client.operationIsCurrent = { [weak self] in self?.isCurrent(ticket) == true }
            result = await client.recoverState(inspection: inspection)
        }
        lock.withLock {
            busy = false
            guard generation == ticket else { return }
            switch result {
            case .success(let receipt):
                self.receipt = receipt
                set(.completed(receipt))
            case .failure(let error): set(.failed(error, inspection: inspection))
            }
        }
    }

    /// Invalidates suspended results after a selected runtime/root change. It never cancels engine work.
    public func invalidate() {
        lock.withLock {
            generation += 1
            receipt = nil
            set(.idle)
        }
    }

    private func beginInspection() -> Int? {
        lock.withLock {
            guard !busy else { return nil }
            generation += 1
            busy = true
            set(.inspecting)
            return generation
        }
    }

    private func beginRecovery(_ inspection: StateInspection) -> Int? {
        lock.withLock {
            guard !busy, case .confirming(let confirmed) = value, confirmed == inspection else { return nil }
            generation += 1
            busy = true
            set(.recovering(inspection))
            return generation
        }
    }

    private func isCurrent(_ ticket: Int) -> Bool { lock.withLock { generation == ticket } }
    private func set(_ state: StoreRecoveryState) { if value != state { value = state } }
}

// MARK: - NullStateRecoveryRepository

/// Safe unregistered default; never performs recovery.
public struct NullStateRecoveryRepository: StateRecoveryRepository {
    public init() {}
    public var lastCompletedReceipt: StateRecoveryResult? { nil }
    public var state: StoreRecoveryState { .idle }
    public func statePublisher() -> AnyPublisher<StoreRecoveryState, Never> { Just(.idle).eraseToAnyPublisher() }
    public func report(_: ToolError) {}
    public func inspect() async {}
    public func requestConfirmation(inspection _: StateInspection) {}
    public func cancelConfirmation() {}
    public func recover(inspection _: StateInspection) async {}
    public func invalidate() {}
}

public extension GlobalValues {
    /// Shared store readiness/recovery surface.
    @GlobalEntry var stateRecoveryRepository: any StateRecoveryRepository = NullStateRecoveryRepository()
}
